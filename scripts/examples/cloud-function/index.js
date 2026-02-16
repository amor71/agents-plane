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

  // Auth — AUTH_SECRET must be configured
  if (!AUTH_SECRET) {
    console.error('AUTH_SECRET not configured — rejecting all requests');
    return res.status(500).json({ error: 'Server misconfigured' });
  }
  const authHeader = req.headers.authorization || '';
  const token = authHeader.replace('Bearer ', '');
  if (token !== AUTH_SECRET) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  // Parse & validate
  const { email, action, model, budget } = req.body;
  if (!email || typeof email !== 'string' || !email.includes('@')) {
    return res.status(400).json({ error: 'Missing or invalid email' });
  }
  if (action && !['provision', 'deprovision'].includes(action)) {
    return res.status(400).json({ error: 'Invalid action (must be provision or deprovision)' });
  }
  if (budget !== undefined && (typeof budget !== 'number' || budget < 0 || budget > 10000)) {
    return res.status(400).json({ error: 'Invalid budget (0-10000)' });
  }

  const username = email.split('@')[0];
  const safeName = username.replace(/\./g, '-').toLowerCase();
  if (!/^[a-z0-9-]+$/.test(safeName) || safeName.length > 30) {
    return res.status(400).json({ error: 'Email username contains invalid characters' });
  }
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

  // Create secret (or update if exists)
  const secretName = `agent-${safeName}-config`;
  const parent = `projects/${PROJECT}`;
  const secretPath = `${parent}/secrets/${secretName}`;

  try {
    await secretManager.createSecret({
      parent,
      secretId: secretName,
      secret: { replication: { automatic: {} } },
    });
    console.log(`Created secret ${secretName}`);
  } catch (err) {
    if (err.code === 6 || err.message?.includes('ALREADY_EXISTS')) {
      console.log(`Secret ${secretName} already exists, adding new version`);
    } else {
      throw err;
    }
  }

  // Always add a new version with latest config
  await secretManager.addSecretVersion({
    parent: secretPath,
    payload: {
      data: Buffer.from(JSON.stringify({ user: email, model, budget })),
    },
  });

  // Grant default compute SA access to the agent's secret
  // (VMs created by CF use the default SA, not per-agent SA)
  const PROJECT_NUMBER = PROJECT.match(/^\d+$/) ? PROJECT : process.env.PROJECT_NUMBER;
  if (PROJECT_NUMBER) {
    const defaultSA = `serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com`;
    try {
      const [policy] = await secretManager.getIamPolicy({ resource: secretPath });
      policy.bindings = policy.bindings || [];
      const alreadyBound = policy.bindings.some(b =>
        b.role === 'roles/secretmanager.secretAccessor' && b.members?.includes(defaultSA)
      );
      if (!alreadyBound) {
        policy.bindings.push({
          role: 'roles/secretmanager.secretAccessor',
          members: [defaultSA],
        });
        await secretManager.setIamPolicy({ resource: secretPath, policy });
        console.log(`Granted secret access to default compute SA`);
      }
    } catch (err) {
      console.warn('Failed to set secret IAM (VM may not access config):', err.message);
    }
  }

  // Also grant access to shared secrets
  for (const sharedName of ['agents-plane-api-key', 'agents-plane-sa-key']) {
    try {
      const sharedPath = `${parent}/secrets/${sharedName}`;
      const [policy] = await secretManager.getIamPolicy({ resource: sharedPath });
      // Skip if already bound (idempotent)
    } catch (err) {
      // Shared secrets may not exist yet, that's fine
    }
  }

  // Startup script lives in GCS — single source of truth
  const startupScriptUrl = 'gs://agents-plane-scripts/startup-script.sh';

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
        scopes: [
          'https://www.googleapis.com/auth/cloud-platform',  // Needed for Secret Manager access
          // TODO: narrow to secretmanager + logging only once per-agent SA is standard
        ],
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
      items: [{ key: 'startup-script-url', value: startupScriptUrl }],
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
