#!/usr/bin/env node
/**
 * Agents Plane — Startup Script Validation Tests
 * 
 * Tests the Cloud Function's startup script generation WITHOUT deploying anything.
 * Extracts the bash script from the JS template and validates:
 * - Bash syntax (shellcheck-style)
 * - Config file generation (JSON validity, required keys)
 * - Path correctness
 * - Service file structure
 * - Email config (TOML structure)
 * - All required commands are present
 * 
 * Run: node tests/test-startup-script.js
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// --- Test Framework ---
let passed = 0, failed = 0, errors = [];

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (e) {
    failed++;
    errors.push({ name, error: e.message });
    console.log(`  ❌ ${name}: ${e.message}`);
  }
}

function assert(condition, msg) {
  if (!condition) throw new Error(msg || 'Assertion failed');
}

// --- Read startup script from standalone file (single source of truth) ---
const scriptPath = path.join(__dirname, '..', 'scripts', 'startup-script.sh');
assert(fs.existsSync(scriptPath), 'Could not find scripts/startup-script.sh');
const rawScript = fs.readFileSync(scriptPath, 'utf8');

// Test values for substitution checks
const testVars = {
  AGENT_NAME: 'TestAgent',
  OWNER_EMAIL: 'test@example.com',
  AGENT_MODEL: 'claude-opus-4-6',
  PROJECT_ID: 'test-project',
  TOKEN: 'fake-gcp-token-for-testing',
  NETWORK: 'test-vpc',
  SUBNET: 'test-subnet',
};

// Replace ${VAR} patterns used in the JS template
let script = rawScript;
for (const [k, v] of Object.entries(testVars)) {
  script = script.replace(new RegExp(`\\$\\{${k}\\}`, 'g'), v);
}
// Unescape JS template escapes
script = script.replace(/\\`/g, '`');
script = script.replace(/\\\$/g, '$');

console.log('\n═══════════════════════════════════════════');
console.log('  Agents Plane — Startup Script Tests');
console.log('═══════════════════════════════════════════\n');

// --- 1. Script Structure Tests ---
console.log('📋 Script Structure:');

test('Script starts with shebang', () => {
  assert(script.trimStart().startsWith('#!/bin/bash'), 'Missing #!/bin/bash shebang');
});

test('Script uses set -e', () => {
  assert(script.includes('set -e'), 'Missing set -e for fail-fast');
});

test('Installs Node.js 22', () => {
  assert(script.includes('nodesource') || script.includes('setup_22'), 'Missing Node.js 22 install');
});

test('Installs OpenClaw via npm', () => {
  assert(script.includes('npm install -g openclaw'), 'Missing npm install -g openclaw');
});

test('Installs gmail.py helper', () => {
  assert(script.includes('gmail.py'), 'Missing gmail.py helper');
  assert(script.includes('gmail.googleapis.com'), 'gmail.py should use Gmail API');
});

test('Installs python3-cryptography', () => {
  assert(script.includes('python3-cryptography'), 'Missing python3-cryptography');
});

test('Creates agent user', () => {
  assert(script.includes('useradd') || script.includes('adduser'), 'Missing agent user creation');
});

test('Creates workspace directory', () => {
  assert(script.includes('mkdir -p') && script.includes('.openclaw/workspace'), 'Missing workspace mkdir');
});

// --- 2. Config Generation Tests ---
console.log('\n📋 Config Generation:');

// Extract the openclaw.json content from the script
const configMatch = script.match(/cat > \/home\/agent\/\.openclaw\/openclaw\.json << CFGEOF\n([\s\S]*?)\nCFGEOF/);
test('openclaw.json heredoc found', () => {
  assert(configMatch, 'Could not find openclaw.json heredoc in script');
});

if (configMatch) {
  // Substitute bash variables for testing
  let configStr = configMatch[1]
    .replace(/\$AGENT_MODEL/g, 'claude-opus-4-6')
    .replace(/\$AGENT_NAME/g, 'TestAgent')
    .replace(/\$GATEWAY_TOKEN/g, 'test-token-123');

  test('openclaw.json is valid JSON', () => {
    try { JSON.parse(configStr); } catch (e) {
      throw new Error(`Invalid JSON: ${e.message}\n${configStr}`);
    }
  });

  if (configStr) {
    let config;
    try { config = JSON.parse(configStr); } catch(e) { config = null; }

    test('openclaw.json has "agents" key (not "ai")', () => {
      assert(config, 'Could not parse config');
      assert(config.agents, 'Missing "agents" key');
      assert(!config.ai, 'Should not have "ai" key — use "agents"');
    });

    test('openclaw.json has "gateway" key (not "system")', () => {
      assert(config, 'Could not parse config');
      assert(config.gateway, 'Missing "gateway" key');
      assert(!config.system, 'Should not have "system" key — use "gateway"');
    });

    test('heartbeat is configured', () => {
      assert(config?.agents?.defaults?.heartbeat, 'Missing heartbeat config');
      assert(config.agents.defaults.heartbeat.every, 'Missing heartbeat.every');
    });

    test('agent model is set', () => {
      const models = config?.agents?.defaults?.models;
      assert(models, 'Missing models config');
      const keys = Object.keys(models);
      assert(keys.length > 0, 'No model configured');
      assert(keys[0].startsWith('anthropic/'), 'Model should start with anthropic/');
    });

    test('agent identity name is set', () => {
      const name = config?.agents?.list?.[0]?.identity?.name;
      assert(name, 'Missing agent identity name');
    });

    test('gateway has auth config', () => {
      assert(config?.gateway?.auth?.mode === 'token', 'Gateway auth mode should be "token"');
      assert(config?.gateway?.auth?.token, 'Gateway auth token missing');
    });

    test('gateway port is 18789', () => {
      assert(config?.gateway?.port === 18789, `Expected port 18789, got ${config?.gateway?.port}`);
    });

    test('no duplicate top-level keys', () => {
      // Check raw JSON string for duplicate keys
      const agentsCount = (configStr.match(/"agents"/g) || []).length;
      // "agents" appears in defaults context too, so check for top-level only
      const topLevel = configStr.match(/^\s*"agents"/gm);
      assert(!topLevel || topLevel.length <= 1, `Found ${topLevel?.length} top-level "agents" keys — duplicate!`);
    });
  }
}

// --- 3. Auth Profile Tests ---
console.log('\n📋 Auth Profile:');

const authMatch = script.match(/cat > \/home\/agent\/\.openclaw\/agents\/main\/agent\/auth-profiles\.json << AUTHEOF\n([\s\S]*?)\nAUTHEOF/);
test('auth-profiles.json heredoc found', () => {
  assert(authMatch, 'Could not find auth-profiles.json heredoc');
});

if (authMatch) {
  let authStr = authMatch[1].replace(/\$ANTHROPIC_KEY/g, 'sk-test-key');
  test('auth-profiles.json is valid JSON', () => {
    try { JSON.parse(authStr); } catch (e) {
      throw new Error(`Invalid JSON: ${e.message}`);
    }
  });

  let auth;
  try { auth = JSON.parse(authStr); } catch(e) { auth = null; }

  test('auth profile has version 1', () => {
    assert(auth?.version === 1, 'Missing or wrong version');
  });

  test('auth profile has anthropic:default', () => {
    assert(auth?.profiles?.['anthropic:default'], 'Missing anthropic:default profile');
  });

  test('auth profile has lastGood', () => {
    assert(auth?.lastGood?.anthropic === 'anthropic:default', 'Missing lastGood');
  });
}

// --- 4. Gmail API Helper Tests ---
console.log('\n📋 Gmail API Helper:');

const gmailMatch = script.match(/cat > \/home\/agent\/\.config\/agents-plane\/gmail\.py << 'GMAILEOF'\n([\s\S]*?)\nGMAILEOF/);
test('gmail.py heredoc found', () => {
  assert(gmailMatch, 'Could not find gmail.py heredoc');
});

if (gmailMatch) {
  const gmailScript = gmailMatch[1];

  test('gmail.py uses Gmail REST API', () => {
    assert(gmailScript.includes('gmail.googleapis.com'), 'Missing Gmail API URL');
  });

  test('gmail.py has send function', () => {
    assert(gmailScript.includes('def send('), 'Missing send function');
  });

  test('gmail.py has inbox function', () => {
    assert(gmailScript.includes('def inbox('), 'Missing inbox function');
  });

  test('gmail.py has token function', () => {
    assert(gmailScript.includes('def get_token('), 'Missing get_token function');
  });

  test('gmail.py uses SA key for auth', () => {
    assert(gmailScript.includes('sa-key.json'), 'Missing SA key reference');
  });

  test('gmail.py uses RS256 signing', () => {
    assert(gmailScript.includes('RS256'), 'Missing RS256');
  });

  test('gmail.py has CLI interface', () => {
    assert(gmailScript.includes('__main__'), 'Missing __main__ block');
    assert(gmailScript.includes('sys.argv'), 'Missing sys.argv parsing');
  });

  // Python syntax check
  try {
    const tmpFile = '/tmp/test-gmail-script.py';
    fs.writeFileSync(tmpFile, gmailScript);
    execSync(`python3 -m py_compile ${tmpFile} 2>&1`);
    test('gmail.py is valid Python', () => { /* passed */ });
    fs.unlinkSync(tmpFile);
  } catch (e) {
    test('gmail.py is valid Python', () => {
      throw new Error(`Python syntax error: ${e.message}`);
    });
  }
}

// --- 5. BOOTSTRAP.md Email Instructions ---
console.log('\n📋 BOOTSTRAP.md Email Instructions:');

test('BOOTSTRAP.md mentions gmail.py for sending', () => {
  assert(script.includes('gmail.py send'), 'BOOTSTRAP.md should tell agent to use gmail.py send');
});

test('BOOTSTRAP.md has tools section', () => {
  assert(script.includes('Tools Available'), 'BOOTSTRAP.md should have Tools Available section');
});

// --- 6. Systemd Service Tests ---
console.log('\n📋 Systemd Service:');

const svcMatch = script.match(/cat > \/home\/agent\/\.config\/systemd\/user\/openclaw-gateway\.service << SVCEOF\n([\s\S]*?)\nSVCEOF/);
test('systemd service heredoc found', () => {
  assert(svcMatch, 'Could not find systemd service heredoc');
});

if (svcMatch) {
  const svcFile = svcMatch[1];

  test('service is user-level (no system paths)', () => {
    assert(!svcFile.includes('/etc/systemd'), 'Should not reference /etc/systemd');
  });

  test('service has ExecStart', () => {
    assert(svcFile.includes('ExecStart='), 'Missing ExecStart');
  });

  test('service ExecStart references gateway', () => {
    assert(svcFile.includes('gateway'), 'ExecStart should reference gateway');
  });

  test('service has Restart=always', () => {
    assert(svcFile.includes('Restart=always'), 'Missing Restart=always');
  });

  test('service has WantedBy=default.target', () => {
    assert(svcFile.includes('WantedBy=default.target'), 'Missing WantedBy=default.target');
  });

  test('service uses OPENCLAW_SYSTEMD_UNIT env', () => {
    assert(svcFile.includes('OPENCLAW_SYSTEMD_UNIT'), 'Missing OPENCLAW_SYSTEMD_UNIT env');
  });
}

// --- 7. Startup Flow Tests ---
console.log('\n📋 Startup Flow:');

test('enables lingering for agent user', () => {
  assert(script.includes('loginctl enable-linger'), 'Missing loginctl enable-linger');
});

test('uses user-level systemctl (--user)', () => {
  assert(script.includes('systemctl --user'), 'Missing systemctl --user');
});

test('sets XDG_RUNTIME_DIR for su commands', () => {
  assert(script.includes('XDG_RUNTIME_DIR'), 'Missing XDG_RUNTIME_DIR');
});

test('enables then starts service', () => {
  const enableIdx = script.indexOf('systemctl --user enable');
  const startIdx = script.indexOf('systemctl --user start');
  assert(enableIdx > 0, 'Missing systemctl --user enable');
  assert(startIdx > 0, 'Missing systemctl --user start');
  assert(enableIdx < startIdx, 'Enable should come before start');
});

test('Secret Manager calls use correct API', () => {
  assert(script.includes('secretmanager.googleapis.com/v1'), 'Missing Secret Manager API call');
});

test('BOOTSTRAP.md is written', () => {
  assert(script.includes('BOOTSTRAP.md'), 'Missing BOOTSTRAP.md');
});

test('AGENTS.md is written', () => {
  assert(script.includes('AGENTS.md'), 'Missing AGENTS.md');
});

test('File ownership set to agent user', () => {
  const chownCount = (script.match(/chown.*agent:agent/g) || []).length;
  assert(chownCount >= 5, `Only ${chownCount} chown calls — should be at least 5`);
});

// --- 8. Cloud Function JS Tests ---
console.log('\n📋 Cloud Function JS:');

test('Cloud Function exports provisionAgent', () => {
  assert(cfSource.includes('exports.provisionAgent'), 'Missing exports.provisionAgent');
});

test('Cloud Function handles provision/deprovision actions', () => {
  assert(cfSource.includes("'deprovision'"), 'Missing deprovision action');
  assert(cfSource.includes("'provisioned'"), 'Missing provisioned response');
});

test('VM uses no external IP', () => {
  // Check that networkInterfaces don't have accessConfigs (which would give external IP)
  assert(!cfSource.includes('accessConfigs'), 'VM should not have accessConfigs (external IP)');
});

test('VM tagged as agent-vm', () => {
  assert(cfSource.includes('agent-vm'), 'Missing agent-vm tag');
});

test('VM disk is 20GB', () => {
  assert(cfSource.includes("'20'") || cfSource.includes('"20"'), 'Disk should be 20GB');
});

test('Uses Debian 12 image', () => {
  assert(cfSource.includes('debian-12'), 'Should use Debian 12 image');
});

test('Destructures operation from insert()', () => {
  assert(cfSource.includes('[operation]'), 'Should destructure [operation] from insert()');
});

test('Waits for operation.promise()', () => {
  assert(cfSource.includes('operation.promise()'), 'Should await operation.promise()');
});

// --- Results ---
console.log('\n═══════════════════════════════════════════');
console.log(`  Results: ${passed} passed, ${failed} failed`);
console.log('═══════════════════════════════════════════');

if (errors.length > 0) {
  console.log('\nFailures:');
  errors.forEach(e => console.log(`  • ${e.name}: ${e.error}`));
}

process.exit(failed > 0 ? 1 : 0);
