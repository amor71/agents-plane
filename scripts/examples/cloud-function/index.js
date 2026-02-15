/**
 * 🤖 Agents Plane — Cloud Function for Agent Provisioning
 *
 * This Cloud Function is triggered by the Apps Script when a user's
 * "AI Agent" toggle is changed in Google Workspace Admin Console.
 *
 * It creates/destroys GCP resources for the agent.
 *
 * Deploy:
 *   gcloud functions deploy provision-agent \
 *     --runtime nodejs20 \
 *     --trigger-http \
 *     --allow-unauthenticated \
 *     --region us-east4 \
 *     --set-env-vars "AUTH_SECRET=your-secret,GCP_PROJECT=your-project,GCP_ZONE=us-east4-b"
 */

const compute = require('@google-cloud/compute');
const { SecretManagerServiceClient } = require('@google-cloud/secret-manager');

const instancesClient = new compute.InstancesClient();
const secretManager = new SecretManagerServiceClient();

const PROJECT = process.env.GCP_PROJECT || process.env.PROJECT_ID || process.env.GCLOUD_PROJECT;
const ZONE = process.env.GCP_ZONE || 'us-east4-b';
const REGION = ZONE.replace(/-[a-z]$/, '');
const AUTH_SECRET = process.env.AUTH_SECRET;
const NETWORK = process.env.NETWORK || 'agents-plane-vpc';
const SUBNET = process.env.SUBNET || 'agents-subnet';
const DEFAULT_VM_TYPE = process.env.DEFAULT_VM_TYPE || 'e2-standard-2';

/**
 * HTTP Cloud Function entry point.
 */
exports.provisionAgent = async (req, res) => {
  // CORS
  res.set('Access-Control-Allow-Origin', '*');
  if (req.method === 'OPTIONS') {
    res.set('Access-Control-Allow-Methods', 'POST');
    res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    return res.status(204).send('');
  }

  // Auth
  const authHeader = req.headers.authorization || '';
  const token = authHeader.replace('Bearer ', '');
  if (AUTH_SECRET && token !== AUTH_SECRET) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  // Parse
  const { email, action, model, budget } = req.body;
  if (!email) {
    return res.status(400).json({ error: 'Missing email' });
  }

  const username = email.split('@')[0];
  const safeName = username.replace(/\./g, '-').toLowerCase();
  const vmName = `agent-${safeName}`;

  try {
    if (action === 'deprovision') {
      await deprovisionAgent(vmName, safeName);
      return res.json({ success: true, action: 'deprovisioned', email });
    }

    const result = await provisionAgent(vmName, safeName, email, model, budget);
    return res.json({ success: true, action: 'provisioned', email, ...result });
  } catch (err) {
    console.error(`Error processing ${action} for ${email}:`, err);
    return res.status(500).json({ error: err.message });
  }
};

/**
 * Provision a new agent VM.
 */
async function provisionAgent(vmName, safeName, email, model = 'claude-opus-4-6', budget = 50) {
  // Check if VM already exists
  try {
    const [instance] = await instancesClient.get({ project: PROJECT, zone: ZONE, instance: vmName });
    if (instance.status === 'TERMINATED') {
      const [startOp] = await instancesClient.start({ project: PROJECT, zone: ZONE, instance: vmName });
      if (startOp && typeof startOp.promise === 'function') await startOp.promise();
      return { status: 'started', vmName };
    }
    return { status: 'already_exists', vmName };
  } catch (err) {
    if (!err.message?.includes('not found') && err.code !== 5) throw err;
    // VM doesn't exist, continue to create
  }

  // Create secret
  const secretName = `agent-${safeName}-config`;
  try {
    const parent = `projects/${PROJECT}`;
    await secretManager.createSecret({
      parent,
      secretId: secretName,
      secret: { replication: { auto: {} } },
    });
    await secretManager.addSecretVersion({
      parent: `${parent}/secrets/${secretName}`,
      payload: {
        data: Buffer.from(JSON.stringify({ user: email, model, budget })),
      },
    });
  } catch (err) {
    if (!err.message.includes('ALREADY_EXISTS')) throw err;
  }

  // Startup script
  const startupScript = `#!/bin/bash
set -e
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq curl wget git jq unzip
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
npm install -g @openclaw/cli
useradd -m -s /bin/bash agent || true
su - agent -c 'mkdir -p ~/.openclaw/workspace'
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
AGENT_NAME="\${INSTANCE_NAME#agent-}"
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | jq -r '.access_token')
CONFIG=$(curl -s "https://secretmanager.googleapis.com/v1/projects/\${PROJECT_ID}/secrets/agent-\${AGENT_NAME}-config/versions/latest:access" -H "Authorization: Bearer \${TOKEN}" | jq -r '.payload.data' | base64 -d)
echo "\$CONFIG" > /home/agent/.openclaw/agent-config.json
chown agent:agent /home/agent/.openclaw/agent-config.json
logger "OpenClaw agent provisioned for \$AGENT_NAME"
`;

  // Create VM
  const config = {
    machineType: `zones/${ZONE}/machineTypes/${DEFAULT_VM_TYPE}`,
    tags: { items: ['agent-vm'] },
    labels: {
      'agent-user': safeName,
      'managed-by': 'agents-plane',
    },
    networkInterfaces: [
      {
        network: `projects/${PROJECT}/global/networks/${NETWORK}`,
        subnetwork: `projects/${PROJECT}/regions/${REGION}/subnetworks/${SUBNET}`,
        // No external IP
      },
    ],
    // Per-agent service accounts can be created later for isolation
    // For now, VMs use the default compute service account
    serviceAccounts: [
      {
        email: 'default',
        scopes: ['https://www.googleapis.com/auth/cloud-platform'],
      },
    ],
    disks: [
      {
        boot: true,
        autoDelete: true,
        initializeParams: {
          sourceImage: 'projects/debian-cloud/global/images/family/debian-12',
          diskSizeGb: '20',
          diskType: `zones/${ZONE}/diskTypes/pd-balanced`,
        },
      },
    ],
    metadata: {
      items: [{ key: 'startup-script', value: startupScript }],
    },
  };

  const instanceResource = {
    name: vmName,
    ...config,
  };

  const [operation] = await instancesClient.insert({
    project: PROJECT,
    zone: ZONE,
    instanceResource,
  });

  // Wait for the LRO to complete (v4+ API)
  if (operation && typeof operation.promise === 'function') {
    await operation.promise();
  }

  return { status: 'created', vmName };
}

/**
 * Deprovision (stop) an agent VM. Does NOT delete to preserve data.
 */
async function deprovisionAgent(vmName, safeName) {
  try {
    const [instance] = await instancesClient.get({ project: PROJECT, zone: ZONE, instance: vmName });
    if (instance.status === 'RUNNING') {
      const [stopOp] = await instancesClient.stop({ project: PROJECT, zone: ZONE, instance: vmName });
      if (stopOp && typeof stopOp.promise === 'function') await stopOp.promise();
    }
    return { status: 'stopped', vmName };
  } catch (err) {
    if (err.message?.includes('not found') || err.code === 5) {
      return { status: 'not_found', vmName };
    }
    throw err;
  }
}

// For local testing
if (require.main === module) {
  const express = require('express');
  const app = express();
  app.use(express.json());
  app.all('/provision-agent', (req, res) => exports.provisionAgent(req, res));
  const port = process.env.PORT || 8080;
  app.listen(port, () => console.log(`Listening on :${port}`));
}
