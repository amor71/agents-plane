/**
 * 🤖 Agents Plane — Google Apps Script Trigger
 *
 * This Apps Script watches for changes to a custom user schema in Google
 * Workspace Admin Console. When an admin enables the "AI Agent" toggle
 * for a user, it triggers a Cloud Function to provision the agent.
 *
 * How admins enable an agent for a user:
 *   1. Go to admin.google.com → Directory → Users
 *   2. Click on the user
 *   3. Click "User information" at the top of the user page
 *   4. Scroll down past the default fields (department, building, etc.)
 *   5. Under "Custom attributes", find "Agent Configuration"
 *   6. Set "Agent Enabled" to Yes
 *   7. Set "Agent Model" — e.g. claude-opus-4-6, gpt-4o, gemini-pro
 *   8. Set "Monthly Budget" — a number in USD (no dollar sign), e.g. 50
 *   9. Click Save
 *
 * Setup (this script):
 *   1. Go to script.google.com and create a new project
 *   2. Paste this code
 *   3. Set up a time-based trigger (every 5 minutes) for `pollForAgentChanges`
 *   4. Configure the constants below
 *   5. Deploy and authorize
 */

// ─── Configuration ───────────────────────────────────────────────

const CONFIG = {
  // Your Cloud Function URL (deployed from examples/cloud-function/)
  CLOUD_FUNCTION_URL: 'https://REGION-PROJECT_ID.cloudfunctions.net/provision-agent',

  // Custom schema name in Google Workspace
  SCHEMA_NAME: 'AgentConfig',

  // Field name in the custom schema
  FIELD_ENABLED: 'agentEnabled',
  FIELD_MODEL: 'agentModel',
  FIELD_BUDGET: 'agentBudget',

  // Shared secret for authenticating with the Cloud Function
  // Store this in Script Properties, not here in production!
  AUTH_SECRET: PropertiesService.getScriptProperties().getProperty('AGENTS_PLANE_SECRET') || 'CHANGE_ME',

  // Domain
  DOMAIN: Session.getEffectiveUser().getEmail().split('@')[1],
};

// ─── Custom Schema Setup ─────────────────────────────────────────

/**
 * Run once to create the custom user schema in Google Workspace.
 * This adds an "Agents Plane" section to each user's profile in Admin Console.
 */
function createCustomSchema() {
  const schema = {
    schemaName: CONFIG.SCHEMA_NAME,
    displayName: 'Agent Configuration',
    fields: [
      {
        fieldName: CONFIG.FIELD_ENABLED,
        fieldType: 'BOOL',
        displayName: 'Agent Enabled',
        readAccessType: 'ADMINS_AND_SELF',
      },
      {
        fieldName: CONFIG.FIELD_MODEL,
        fieldType: 'STRING',
        displayName: 'Agent Model (e.g. claude-opus-4-6, gpt-4o, gemini-pro)',
        readAccessType: 'ADMINS_AND_SELF',
      },
      {
        fieldName: CONFIG.FIELD_BUDGET,
        fieldType: 'INT64',
        displayName: 'Monthly Budget in USD (e.g. 50, 100, 200)',
        readAccessType: 'ADMINS_AND_SELF',
      },
    ],
  };

  try {
    AdminDirectory.Schemas.insert(schema, 'my_customer');
    Logger.log('✅ Custom schema created successfully');
  } catch (e) {
    if (e.message.includes('already exists')) {
      Logger.log('ℹ️ Schema already exists');
    } else {
      Logger.log('❌ Error: ' + e.message);
      throw e;
    }
  }
}

// ─── Polling for Changes ─────────────────────────────────────────

/**
 * Main trigger function. Call this on a schedule (every 5 min).
 * Checks all users for agent-enabled status and provisions/deprovisions as needed.
 */
function pollForAgentChanges() {
  const scriptProps = PropertiesService.getScriptProperties();
  const processedKey = 'PROCESSED_USERS';
  const processed = JSON.parse(scriptProps.getProperty(processedKey) || '{}');

  let pageToken = null;
  do {
    const page = AdminDirectory.Users.list({
      customer: 'my_customer',
      projection: 'full',
      customFieldMask: CONFIG.SCHEMA_NAME,
      maxResults: 100,
      pageToken: pageToken,
    });

    if (!page.users) break;

    for (const user of page.users) {
      const email = user.primaryEmail;
      const customSchemas = user.customSchemas || {};
      const agentData = customSchemas[CONFIG.SCHEMA_NAME] || {};
      const isEnabled = agentData[CONFIG.FIELD_ENABLED] === true;
      const wasEnabled = processed[email] === true;

      if (isEnabled && !wasEnabled) {
        // Agent was just enabled → provision
        Logger.log(`🚀 Provisioning agent for ${email}`);
        const result = callProvisionFunction(email, {
          action: 'provision',
          model: agentData[CONFIG.FIELD_MODEL] || 'gpt-4o',
          budget: agentData[CONFIG.FIELD_BUDGET] || 50,
        });
        if (result.success) {
          processed[email] = true;
          Logger.log(`✅ Agent provisioned for ${email}`);
        } else {
          Logger.log(`❌ Failed to provision for ${email}: ${result.error}`);
        }
      } else if (!isEnabled && wasEnabled) {
        // Agent was disabled → deprovision
        Logger.log(`🛑 Deprovisioning agent for ${email}`);
        const result = callProvisionFunction(email, { action: 'deprovision' });
        if (result.success) {
          delete processed[email];
          Logger.log(`✅ Agent deprovisioned for ${email}`);
        }
      }
    }

    pageToken = page.nextPageToken;
  } while (pageToken);

  scriptProps.setProperty(processedKey, JSON.stringify(processed));
}

// ─── Cloud Function Caller ───────────────────────────────────────

function callProvisionFunction(email, params) {
  try {
    const payload = {
      email: email,
      ...params,
      timestamp: new Date().toISOString(),
    };

    const response = UrlFetchApp.fetch(CONFIG.CLOUD_FUNCTION_URL, {
      method: 'post',
      contentType: 'application/json',
      payload: JSON.stringify(payload),
      headers: {
        'Authorization': `Bearer ${CONFIG.AUTH_SECRET}`,
      },
      muteHttpExceptions: true,
    });

    const code = response.getResponseCode();
    const body = JSON.parse(response.getContentText());

    if (code >= 200 && code < 300) {
      return { success: true, data: body };
    } else {
      return { success: false, error: body.error || `HTTP ${code}` };
    }
  } catch (e) {
    return { success: false, error: e.message };
  }
}

// ─── Utility Functions ───────────────────────────────────────────

/**
 * Manually trigger provisioning for a single user (for testing).
 */
function testProvision() {
  const result = callProvisionFunction('test@' + CONFIG.DOMAIN, {
    action: 'provision',
    model: 'gpt-4o',
    budget: 50,
  });
  Logger.log(JSON.stringify(result, null, 2));
}

/**
 * Set up the 5-minute polling trigger automatically.
 * Called by setup.sh via the Apps Script API, or run manually.
 * Safe to call multiple times — deletes existing triggers first.
 */
function setupTrigger() {
  // Remove any existing triggers for pollForAgentChanges
  const triggers = ScriptApp.getProjectTriggers();
  for (const trigger of triggers) {
    if (trigger.getHandlerFunction() === 'pollForAgentChanges') {
      ScriptApp.deleteTrigger(trigger);
    }
  }

  // Create a new 5-minute trigger
  ScriptApp.newTrigger('pollForAgentChanges')
    .timeBased()
    .everyMinutes(5)
    .create();

  Logger.log('✅ Trigger created: pollForAgentChanges every 5 minutes');
}

/**
 * List all users with agents enabled.
 */
function listEnabledAgents() {
  let pageToken = null;
  const agents = [];

  do {
    const page = AdminDirectory.Users.list({
      customer: 'my_customer',
      projection: 'full',
      customFieldMask: CONFIG.SCHEMA_NAME,
      maxResults: 100,
      pageToken: pageToken,
    });

    if (!page.users) break;

    for (const user of page.users) {
      const agentData = (user.customSchemas || {})[CONFIG.SCHEMA_NAME] || {};
      if (agentData[CONFIG.FIELD_ENABLED]) {
        agents.push({
          email: user.primaryEmail,
          model: agentData[CONFIG.FIELD_MODEL] || 'default',
          budget: agentData[CONFIG.FIELD_BUDGET] || 50,
        });
      }
    }

    pageToken = page.nextPageToken;
  } while (pageToken);

  Logger.log(`Found ${agents.length} enabled agents:`);
  Logger.log(JSON.stringify(agents, null, 2));
  return agents;
}
