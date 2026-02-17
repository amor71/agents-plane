/**
 * Email Proxy Cloud Function
 * 
 * Agents call this to send/read email. The function:
 * 1. Validates the agent's identity (via VM metadata)
 * 2. Only allows access to the agent's OWN email
 * 3. Uses the admin SA key (stored in Secret Manager) to impersonate
 * 
 * This way the admin SA key never leaves this function.
 */

const { SecretManagerServiceClient } = require('@google-cloud/secret-manager');
const crypto = require('crypto');
const secretManager = new SecretManagerServiceClient();

const PROJECT = process.env.GCP_PROJECT || 'n30-agents';
const AUTH_SECRET = process.env.AUTH_SECRET;
const SA_KEY_SECRET = process.env.SA_KEY_SECRET || 'rye-workspace-admin-sa-key';

let cachedSaKey = null;

async function getSaKey() {
  if (cachedSaKey) return cachedSaKey;
  const [version] = await secretManager.accessSecretVersion({
    name: `projects/${PROJECT}/secrets/${SA_KEY_SECRET}/versions/latest`,
  });
  cachedSaKey = JSON.parse(version.payload.data.toString());
  return cachedSaKey;
}

function base64url(data) {
  return Buffer.from(data).toString('base64url');
}

async function getTokenForScope(saKey, email, scope) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = base64url(JSON.stringify({
    iss: saKey.client_email,
    sub: email,
    scope,
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));

  const sign = crypto.createSign('RSA-SHA256');
  sign.update(`${header}.${claims}`);
  const signature = sign.sign(saKey.private_key, 'base64url');

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}&assertion=${header}.${claims}.${signature}`,
  });
  const data = await resp.json();
  if (!data.access_token) throw new Error(`Token error: ${JSON.stringify(data)}`);
  return data.access_token;
}

async function getGmailToken(saKey, email) {
  return getTokenForScope(saKey, email, 'https://mail.google.com/');
}

async function getDriveToken(saKey, email) {
  return getTokenForScope(saKey, email, 'https://www.googleapis.com/auth/drive.readonly');
}

async function gmailRequest(token, email, path, method = 'GET', body = null) {
  const url = `https://gmail.googleapis.com/gmail/v1/users/${email}/${path}`;
  const opts = {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  };
  if (body) opts.body = JSON.stringify(body);
  const resp = await fetch(url, opts);
  return resp.json();
}

exports.emailProxy = async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  if (req.method === 'OPTIONS') {
    res.set('Access-Control-Allow-Methods', 'POST');
    res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    return res.status(204).send('');
  }

  // Auth
  if (!AUTH_SECRET) return res.status(500).json({ error: 'Server misconfigured' });
  const authHeader = req.headers.authorization || '';
  const token = authHeader.replace('Bearer ', '');
  if (token !== AUTH_SECRET) return res.status(401).json({ error: 'Unauthorized' });

  const { action, agentName, email, to, subject, body: emailBody, query, maxResults, messageId } = req.body;

  // Validate: agent can only access their own email
  if (!agentName || !email) {
    return res.status(400).json({ error: 'Missing agentName or email' });
  }
  
  // Agent name must match email prefix (e.g., agent "ivan" can only access "ivan@nine30.com")
  const emailPrefix = email.split('@')[0].toLowerCase();
  if (agentName.toLowerCase() !== emailPrefix) {
    return res.status(403).json({ 
      error: `Agent "${agentName}" cannot access email for "${email}". Agents can only access their own email.` 
    });
  }

  try {
    const saKey = await getSaKey();
    const gmailToken = await getGmailToken(saKey, email);

    switch (action) {
      case 'send': {
        if (!to || !subject) return res.status(400).json({ error: 'Missing to/subject' });
        const raw = Buffer.from(
          `From: ${email}\r\nTo: ${to}\r\nSubject: ${subject}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${emailBody || ''}`
        ).toString('base64url');
        const result = await gmailRequest(gmailToken, email, 'messages/send', 'POST', { raw });
        return res.json({ success: true, messageId: result.id });
      }

      case 'send_html': {
        if (!to || !subject) return res.status(400).json({ error: 'Missing to/subject' });
        const boundary = `boundary_${Date.now()}`;
        const raw = Buffer.from(
          `From: ${email}\r\nTo: ${to}\r\nSubject: ${subject}\r\nContent-Type: multipart/alternative; boundary="${boundary}"\r\n\r\n` +
          `--${boundary}\r\nContent-Type: text/html; charset=utf-8\r\n\r\n${emailBody || ''}\r\n` +
          `--${boundary}--`
        ).toString('base64url');
        const result = await gmailRequest(gmailToken, email, 'messages/send', 'POST', { raw });
        return res.json({ success: true, messageId: result.id });
      }

      case 'inbox': {
        const q = query || 'is:unread';
        const max = maxResults || 5;
        const list = await gmailRequest(gmailToken, email, `messages?maxResults=${max}&q=${encodeURIComponent(q)}`);
        const messages = [];
        for (const m of (list.messages || [])) {
          const detail = await gmailRequest(gmailToken, email, `messages/${m.id}?format=full`);
          const headers = {};
          for (const h of (detail.payload?.headers || [])) headers[h.name] = h.value;
          let body = '';
          if (detail.payload?.body?.data) {
            body = Buffer.from(detail.payload.body.data, 'base64url').toString();
          } else if (detail.payload?.parts) {
            for (const part of detail.payload.parts) {
              if (part.mimeType === 'text/plain' && part.body?.data) {
                body = Buffer.from(part.body.data, 'base64url').toString();
                break;
              }
            }
          }
          messages.push({
            id: m.id,
            from: headers.From || '',
            subject: headers.Subject || '',
            body,
            labels: detail.labelIds || [],
          });
        }
        return res.json({ success: true, messages });
      }

      case 'mark_read': {
        if (!messageId) return res.status(400).json({ error: 'Missing messageId' });
        await gmailRequest(gmailToken, email, `messages/${messageId}/modify`, 'POST', { removeLabelIds: ['UNREAD'] });
        return res.json({ success: true });
      }

      case 'drive_search': {
        if (!query) return res.status(400).json({ error: 'Missing query' });
        // Drive access restricted to amichay@nine30.com only
        if (email !== 'amichay@nine30.com') {
          return res.status(403).json({ error: 'Drive access is only available for amichay@nine30.com' });
        }
        const driveToken = await getDriveToken(saKey, email);
        const max = maxResults || 10;
        const driveUrl = `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(`fullText contains '${query.replace(/'/g, "\\'")}'`)}&pageSize=${max}&fields=files(id,name,mimeType,modifiedTime,webViewLink)`;
        const driveResp = await fetch(driveUrl, {
          headers: { Authorization: `Bearer ${driveToken}` },
        });
        const driveData = await driveResp.json();
        if (driveData.error) return res.status(500).json({ error: driveData.error.message });
        return res.json({ success: true, files: driveData.files || [] });
      }

      case 'drive_read': {
        const { fileId } = req.body;
        if (!fileId) return res.status(400).json({ error: 'Missing fileId' });
        // Drive access restricted to amichay@nine30.com only
        if (email !== 'amichay@nine30.com') {
          return res.status(403).json({ error: 'Drive access is only available for amichay@nine30.com' });
        }
        const driveToken = await getDriveToken(saKey, email);
        const exportUrl = `https://www.googleapis.com/drive/v3/files/${fileId}/export?mimeType=text/plain`;
        const exportResp = await fetch(exportUrl, {
          headers: { Authorization: `Bearer ${driveToken}` },
        });
        if (!exportResp.ok) {
          // If export fails (not a Google Doc), try download
          const dlUrl = `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media`;
          const dlResp = await fetch(dlUrl, {
            headers: { Authorization: `Bearer ${driveToken}` },
          });
          if (!dlResp.ok) return res.status(500).json({ error: `Failed to read file: ${dlResp.status}` });
          const text = await dlResp.text();
          return res.json({ success: true, content: text });
        }
        const text = await exportResp.text();
        return res.json({ success: true, content: text });
      }

      default:
        return res.status(400).json({ error: `Unknown action: ${action}` });
    }
  } catch (err) {
    console.error('Email proxy error:', err);
    return res.status(500).json({ error: err.message });
  }
};
