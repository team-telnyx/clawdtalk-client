#!/usr/bin/env node
/**
 * ClawdTalk WebSocket Client v1.3.0
 *
 * Connects to ClawdTalk server and routes voice calls to your Clawdbot gateway.
 * Phone → STT → Gateway Agent → TTS → Phone
 *
 * v1.3.0: Instant approval via WebSocket (no more polling delay)
 *
 * Env vars: OPENCLAW_GATEWAY_URL, CLAWDBOT_GATEWAY_URL, OPENCLAW_GATEWAY_TOKEN, CLAWDBOT_GATEWAY_TOKEN
 * Endpoints: https://clawdtalk.com (WebSocket), http://127.0.0.1:<port> (local gateway)
 * Reads: skill-config.json
 * Writes: none
 */

const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');

/**
 * Resolve ${ENV_VAR} references in config values.
 * Returns the original value if the env var is not set.
 */
function resolveEnvVar(value) {
  if (typeof value !== 'string') return value;
  const match = value.match(/^\$\{([A-Z_][A-Z0-9_]*)\}$/);
  if (match) {
    const envVal = process.env[match[1]];
    return envVal !== undefined ? envVal : value;
  }
  return value;
}

const SKILL_DIR = path.dirname(__dirname);
const CONFIG_FILE = path.join(SKILL_DIR, 'skill-config.json');

// Reconnection with exponential backoff
const RECONNECT_DELAY_MIN = 5000;
const RECONNECT_DELAY_MAX = 180000;
const DEFAULT_GREETING = "Hey, what's up?";

// Gateway defaults (overridden by skill-config.json values set during setup)
const DEFAULT_GATEWAY_URL = 'http://127.0.0.1:18789';
const DEFAULT_AGENT_ID = 'main';

// Default voice context with drip progress updates
const DEFAULT_VOICE_CONTEXT = `[VOICE CALL ACTIVE] Voice call in progress. Speech is transcribed to text. Your response is converted to speech via TTS.

VOICE RULES:
- Keep responses SHORT (1-3 sentences). This is a phone call.
- Speak naturally. NO markdown, NO bullet points, NO asterisks, NO emoji.
- Be direct and conversational.
- Numbers: say naturally ("fifteen hundred" not "1,500").
- Don't repeat back what the caller said.
- You have FULL tool access: Slack, memory, web search, etc. Use them when needed.
- NEVER output raw JSON, function calls, or code. Everything you say will be spoken aloud.

DRIP PROGRESS UPDATES:
- The caller is waiting on the phone. Keep them informed with brief progress updates.
- After each tool call or significant step, respond with a SHORT update: "Checking Slack now...", "Found 3 messages, reading through them...", "Pulling up the PR details..."
- Be specific about what you're doing, not generic. "Looking at your calendar" not "Processing..."
- These updates are spoken aloud immediately, so they fill silence while you work.
- Don't wait until the end to summarize — drip information as you find it.

APPROVAL REQUESTS (IMPORTANT):
- Before performing any SENSITIVE or DESTRUCTIVE action, you MUST request approval first.
- This sends a push notification to the user's phone. They approve or deny from the app.
- Actions that REQUIRE approval: deleting repos/files/data, sending messages on behalf of the user (Slack, email, tweets), making purchases, posting to social media, any irreversible action.
- To request approval, use the approval.sh script: exec approval.sh request "<description of action>"
- Add --biometric for high-security actions (financial, destructive).
- Tell the caller EXPLICITLY: "I'm sending a notification to your phone now for you to approve." Then wait for the result.
- Result handling:
  - "approved" → proceed with the action and confirm completion
  - "denied" → say "No problem, I won't do that" and move on
  - "timeout" → say "The notification timed out. Would you like me to try again, or would you like to confirm by voice instead? Just say approve or deny."
  - "no_devices" → say "You don't have any devices registered for notifications. Would you like to confirm by voice? Say approve or deny."
  - "no_devices_reached" → say "The notification couldn't be delivered to your phone. Would you like to confirm by voice instead? Say approve or deny."
- If the user confirms by voice (says "approve", "yes", "go ahead"), treat it as approved and proceed.
- Actions that do NOT need approval: reading data, searching, checking status, answering questions, looking things up.`;

// Parse command line args for server override
function parseArgs() {
  var args = process.argv.slice(2);
  var serverOverride = null;
  for (var i = 0; i < args.length; i++) {
    if (args[i] === '--server' && args[i + 1]) {
      serverOverride = args[i + 1];
    }
  }
  return { serverOverride: serverOverride };
}

class ClawdTalkClient {
  constructor() {
    this.ws = null;
    this.config = null;
    this.reconnectTimer = null;
    this.isShuttingDown = false;
    this.pingTimer = null;
    this.pongTimeout = null;
    this.conversations = new Map();
    this.args = parseArgs();

    // Exponential backoff for reconnection
    this.reconnectAttempts = 0;
    this.currentReconnectDelay = RECONNECT_DELAY_MIN;

    // Gateway
    this.gatewayToolsUrl = null;
    this.gatewayToken = null;
    this.mainAgentId = 'main';
    this.voiceContext = DEFAULT_VOICE_CONTEXT;
    this.greeting = DEFAULT_GREETING;
    
    // Personalization
    this.ownerName = null;
    this.agentName = null;

    this.loadConfig();
    this.loadSkillConfig();

    process.on('SIGINT', this.shutdown.bind(this, 'SIGINT'));
    process.on('SIGTERM', this.shutdown.bind(this, 'SIGTERM'));
    
    process.on('uncaughtException', function(err) {
      this.log('ERROR', 'Uncaught exception: ' + err.message);
      if (err.code === 'ENOTFOUND' || err.message.includes('ECONNREFUSED') || 
          err.message.includes('getaddrinfo') || err.message.includes('socket')) {
        this.log('WARN', 'Network error, attempting reconnection...');
        if (this.ws) { try { this.ws.close(); } catch (e) {} }
        this.scheduleReconnect();
      } else {
        this.log('FATAL', 'Unrecoverable error, exiting...');
        process.exit(1);
      }
    }.bind(this));

    process.on('unhandledRejection', function(reason) {
      this.log('ERROR', 'Unhandled rejection: ' + (reason ? reason.toString() : 'unknown'));
    }.bind(this));
  }

  loadConfig() {
    try {
      this.config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
      
      // Resolve env var references in key config values
      this.config.api_key = resolveEnvVar(this.config.api_key);
      this.config.server = resolveEnvVar(this.config.server);
      
      // Command line override takes precedence
      if (this.args.serverOverride) {
        this.config.server = this.args.serverOverride;
        this.log('INFO', 'Server override: ' + this.config.server);
      } else if (!this.config.server) {
        this.config.server = 'https://clawdtalk.com';
      }

      if (!this.config.api_key) throw new Error('No API key configured');
      
      // Store for later use (SMS replies, etc)
      this.apiKey = this.config.api_key;
      this.baseUrl = this.config.server;
      
      this.log('INFO', 'Config loaded -> ' + this.config.server);
    } catch (err) {
      this.log('ERROR', 'Config: ' + err.message);
      process.exit(1);
    }
  }

  loadSkillConfig() {
    // Gateway config from skill-config.json (set during setup.sh) with env var fallbacks
    var gatewayUrl = resolveEnvVar(this.config.gateway_url || '') || process.env.OPENCLAW_GATEWAY_URL || process.env.CLAWDBOT_GATEWAY_URL || DEFAULT_GATEWAY_URL;
    this.gatewayToolsUrl = gatewayUrl.replace(/\/$/, '') + '/tools/invoke';
    this.gatewayToken = resolveEnvVar(this.config.gateway_token || '') || process.env.OPENCLAW_GATEWAY_TOKEN || process.env.CLAWDBOT_GATEWAY_TOKEN || '';
    this.mainAgentId = this.config.agent_id || DEFAULT_AGENT_ID;

    this.greeting = this.config.greeting || DEFAULT_GREETING;
    
    // Load names for voice context
    this.ownerName = this.config.owner_name || null;
    this.agentName = this.config.agent_name || null;
    
    // Inject names into voice context if available
    if (this.ownerName || this.agentName) {
      var nameContext = '\n\nIDENTITY:';
      if (this.agentName) nameContext += '\n- Your name is ' + this.agentName + '.';
      if (this.ownerName) nameContext += '\n- You are speaking with ' + this.ownerName + '. Use their name naturally in conversation.';
      this.voiceContext += nameContext;
    }

    if (this.ownerName) this.log('INFO', 'Owner: ' + this.ownerName);
    if (this.agentName) this.log('INFO', 'Agent: ' + this.agentName);
    this.log('INFO', 'Gateway tools: ' + this.gatewayToolsUrl);
    this.log('INFO', 'Main agent: ' + this.mainAgentId);
  }

  log(level, msg) {
    console.log('[' + new Date().toISOString() + '] ' + level + ': ' + msg);
  }

  // ── Connection ──────────────────────────────────────────────

  async connect() {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
    if (this.isShuttingDown) return;

    var serverUrl = this.config.server.replace(/^http/, 'ws');
    this.log('INFO', 'Connecting to ' + serverUrl + '...');

    this.ws = new WebSocket(serverUrl + '/ws', { handshakeTimeout: 10000 });
    this.ws.on('open', this.onOpen.bind(this));
    this.ws.on('message', this.onMessage.bind(this));
    this.ws.on('close', this.onClose.bind(this));
    this.ws.on('error', function(err) {
      this.log('ERROR', 'WS: ' + err.message);
      if (err.message && err.message.indexOf('429') !== -1) {
        this.log('WARN', 'Rate limited — waiting 60s');
        this._nextReconnectDelay = 60000;
      }
    }.bind(this));
    this.ws.on('ping', function() { if (this.ws) this.ws.pong(); }.bind(this));
    this.ws.on('pong', function() { if (this.pongTimeout) { clearTimeout(this.pongTimeout); this.pongTimeout = null; } }.bind(this));
  }

  onOpen() {
    this.log('INFO', 'Connected, authenticating...');
    // Send auth with optional name info for assistant personalization
    var authMsg = { 
      type: 'auth', 
      api_key: this.config.api_key 
    };
    if (this.ownerName) authMsg.owner_name = this.ownerName;
    if (this.agentName) authMsg.agent_name = this.agentName;
    this.ws.send(JSON.stringify(authMsg));
  }

  async onMessage(data) {
    var msg;
    try { msg = JSON.parse(data.toString()); } catch (e) { return; }

    // Debug: log all incoming messages
    if (process.env.DEBUG) {
      this.log('DEBUG', 'WS msg: ' + JSON.stringify(msg).substring(0, 300));
    }

    if (msg.type === 'auth_ok') {
      this.log('INFO', 'Authenticated (v1.3.0 agentic mode)');
      this.reconnectAttempts = 0;
      this.currentReconnectDelay = RECONNECT_DELAY_MIN;
      this.startPing();
    } else if (msg.type === 'auth_error') {
      this.log('ERROR', 'Auth failed: ' + msg.message);
      this.isShuttingDown = true;
    } else if (msg.type === 'event') {
      await this.handleEvent(msg);
    }
  }

  // ── Call Events ─────────────────────────────────────────────

  async handleEvent(msg) {
    var event = msg.event;
    var callId = msg.call_id;

    // Handle context_request (server asking for context at call start)
    if (event === 'context_request') {
      this.log('INFO', 'Call started (context_request): ' + callId);
      this.conversations.set(callId, [
        { role: 'system', content: this.voiceContext }
      ]);
      
      // Send context response back to server
      var contextResponse = {
        type: 'context_response',
        call_id: callId,
        context: {
          memory: 'Voice call with full agent capabilities. Tools available: Slack messaging, web search, and more.',
          system_prompt: this.voiceContext
        }
      };
      if (this.ws && this.ws.readyState === 1) {
        this.ws.send(JSON.stringify(contextResponse));
        this.log('INFO', 'Context sent for call: ' + callId);
      }
      
      // Send greeting
      await this.sendResponse(callId, this.greeting);
      this.log('INFO', 'Greeting sent');
      return;
    }

    // Also handle call.started for compatibility
    if (event === 'call.started') {
      var direction = msg.direction || 'inbound';
      if (!this.conversations.has(callId)) {
        this.conversations.set(callId, [
          { role: 'system', content: this.voiceContext }
        ]);
      }
      this.log('INFO', 'Call started: ' + callId + ' direction=' + direction);
      
      if (direction === 'inbound' && !this.conversations.get(callId)._greeted) {
        await this.sendResponse(callId, this.greeting);
        this.conversations.get(callId)._greeted = true;
        this.log('INFO', 'Greeting sent for inbound call');
      }
      return;
    }

    if (event === 'call.ended') {
      this.conversations.delete(callId);
      this.log('INFO', 'Call ended: ' + callId);
      
      // Report call outcome to user
      this.reportCallOutcome(msg);
      return;
    }

    // Handle deep_tool_request (Voice AI asking for complex query via Clawdbot)
    if (event === 'deep_tool_request') {
      var requestId = msg.request_id;
      var query = msg.query || '';
      this.log('INFO', 'Deep tool request [' + requestId + ']: ' + query.substring(0, 100));
      
      // Process via full Clawdbot agent
      this.handleDeepToolRequest(callId, requestId, query, msg.context || {});
      return;
    }

    // Handle SMS received - forward to bot and send reply
    if (event === 'sms.received') {
      var smsFrom = msg.from;
      var smsBody = msg.body || '';
      var messageId = msg.message_id;
      this.log('INFO', 'SMS received from ' + (smsFrom ? smsFrom.substring(0, 6) + '***' : 'unknown') + ': ' + smsBody.substring(0, 50));
      
      // Process via Clawdbot and send reply
      this.handleInboundSms(smsFrom, smsBody, messageId);
      return;
    }

    // Handle approval response (instant WebSocket notification)
    if (event === 'approval.responded') {
      var approvalRequestId = msg.request_id;
      var decision = msg.decision;
      this.log('INFO', 'Approval response via WS: ' + approvalRequestId + ' -> ' + decision);
      
      var pending = this.pendingApprovals.get(approvalRequestId);
      if (pending) {
        clearTimeout(pending.timeout);
        this.pendingApprovals.delete(approvalRequestId);
        pending.resolve(decision);
      }
      return;
    }

    // Handle walkie_request (Clawdie-Talkie push-to-talk)
    if (event === 'walkie_request') {
      var walkieRequestId = msg.request_id;
      var walkieTranscript = msg.transcript || '';
      var walkieSessionKey = msg.session_key || 'agent:main:main';
      this.log('INFO', 'Walkie request [' + walkieRequestId + ']: ' + walkieTranscript.substring(0, 100));
      this.handleWalkieRequest(walkieRequestId, walkieTranscript, walkieSessionKey);
      return;
    }

    // Log unhandled events for debugging
    if (process.env.DEBUG) {
      this.log('DEBUG', 'Unhandled event: ' + event);
    }
  }

  // ── Deep Tool Handler ───────────────────────────────────────

  // Keywords that indicate a sensitive/destructive action needing approval
  isSensitiveRequest(query) {
    var lower = query.toLowerCase();
    var sensitivePatterns = [
      'delete', 'remove', 'destroy', 'drop',
      'send message', 'send email', 'send slack', 'send sms', 'send text',
      'post to', 'tweet', 'publish',
      'repo', 'repository', 'github',  // Any repo/GitHub action is sensitive
      'push to', 'merge', 'deploy',
      'transfer', 'payment', 'purchase', 'buy',
      'add file', 'add a file', 'modify', 'change',
      'commit', 'write to',
    ];
    return sensitivePatterns.some(function(p) { return lower.includes(p); });
  }

  async handleDeepToolRequest(callId, requestId, query, context) {
    try {
      // TEST PHRASE: "send test push" or "test notification" triggers approval directly
      var lowerQuery = query.toLowerCase();
      if (lowerQuery.includes('test push') || lowerQuery.includes('test notification') || lowerQuery.includes('send a test')) {
        this.log('INFO', 'Test phrase detected - triggering approval push');
        var approvalResult = await this.triggerTestApproval();
        var responseText = approvalResult;
        if (approvalResult === 'approved') {
          responseText = 'You approved the test notification. The push system is working correctly.';
        } else if (approvalResult === 'denied') {
          responseText = 'You denied the test notification. The push system is working, you just said no.';
        }
        this.sendDeepToolResult(requestId, responseText);
        this.log('INFO', 'Deep tool complete [' + requestId + ']: ' + responseText.substring(0, 100));
        return;
      }

      // Check if this is a sensitive action that needs approval
      if (this.isSensitiveRequest(query)) {
        this.log('INFO', 'Sensitive request detected, requesting approval: ' + query.substring(0, 80));
        
        // Tell the caller we're sending a notification
        this.sendDeepToolProgress(requestId, 'Sending you a notification for approval.');
        
        var approvalDecision = await this.requestApproval(query.substring(0, 200));
        
        if (approvalDecision === 'approved') {
          this.sendDeepToolProgress(requestId, 'I see you approved that. Let me take care of it now.');
          this.log('INFO', 'Approval granted, routing to agent');
          // Fall through to route to agent below
        } else if (approvalDecision === 'denied') {
          this.sendDeepToolProgress(requestId, 'I see you denied that request.');
          this.sendDeepToolResult(requestId, 'No problem, I won\'t do that.');
          this.log('INFO', 'Approval denied by user');
          return;
        } else if (approvalDecision === 'no_devices' || approvalDecision === 'no_devices_reached') {
          this.log('INFO', 'No devices for approval, skipping approval and routing directly');
          // No devices — skip approval entirely and route to agent
        } else if (approvalDecision === 'timeout') {
          this.sendDeepToolResult(requestId, 'The approval request timed out. Would you like to try again?');
          this.log('INFO', 'Approval timed out');
          return;
        }
      }
      
      // Route to main session via tools/invoke sessions_send - uses full agent context/memory
      var voicePrefix = '[VOICE CALL] Respond concisely for speech. No markdown, no lists, no URLs. Do NOT request approval — it has already been handled. Just perform the action directly. ';
      
      // Use the main agent session - always route to main session
      var mainSessionKey = 'agent:main:main';
      
      this.log('DEBUG', 'Deep tool calling Gateway: url=' + this.gatewayToolsUrl + ' session=' + mainSessionKey + ' hasToken=' + !!this.gatewayToken);
      
      var response = await fetch(this.gatewayToolsUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.gatewayToken
        },
        body: JSON.stringify({
          tool: 'sessions_send',
          args: {
            sessionKey: mainSessionKey,
            message: voicePrefix + query,
            timeoutSeconds: 90
          }
        }),
        signal: AbortSignal.timeout(120000)
      });
      
      if (!response.ok) {
        var errText = await response.text();
        this.log('ERROR', 'sessions_send failed: ' + response.status + ' ' + errText);
        this.sendDeepToolResult(requestId, 'Sorry, I had trouble reaching the agent.');
        return;
      }
      
      var result = await response.json();
      this.log('DEBUG', 'Gateway response: ' + JSON.stringify(result).substring(0, 500));
      
      // Extract reply from the nested response structure
      var reply = '';
      if (result.result && result.result.details && result.result.details.reply) {
        reply = result.result.details.reply;
      } else if (result.result && result.result.content) {
        // Try to parse from content array
        var content = result.result.content;
        if (Array.isArray(content) && content[0] && content[0].text) {
          try {
            var parsed = JSON.parse(content[0].text);
            reply = parsed.reply || '';
          } catch (e) {
            reply = content[0].text;
          }
        }
      }
      
      if (!reply || reply === 'HEARTBEAT_OK') {
        reply = 'Done.';
      }
      
      // Clean for voice output
      var cleanedResult = this.cleanForVoice(reply);
      this.sendDeepToolResult(requestId, cleanedResult);
      this.log('INFO', 'Deep tool complete [' + requestId + ']: ' + cleanedResult.substring(0, 100));

    } catch (err) {
      if (err.name === 'TimeoutError' || err.name === 'AbortError') {
        this.log('ERROR', 'Deep tool timed out');
        this.sendDeepToolResult(requestId, 'That took too long. Try asking again.');
      } else {
        this.log('ERROR', 'Deep tool failed: ' + err.message);
        this.sendDeepToolResult(requestId, 'Sorry, I had trouble with that request.');
      }
    }
  }

  // ── Walkie-Talkie Handler ──────────────────────────────────

  async handleWalkieRequest(requestId, transcript, sessionKey) {
    try {
      var voicePrefix = '[WALKIE-TALKIE] Push-to-talk message. Respond concisely for speech (1-3 sentences). No markdown, no lists, no URLs. ';

      this.log('DEBUG', 'Walkie calling Gateway: url=' + this.gatewayToolsUrl + ' session=' + sessionKey);

      var response = await fetch(this.gatewayToolsUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.gatewayToken
        },
        body: JSON.stringify({
          tool: 'sessions_send',
          args: {
            sessionKey: sessionKey,
            message: voicePrefix + transcript,
            timeoutSeconds: 90
          }
        }),
        signal: AbortSignal.timeout(120000)
      });

      if (!response.ok) {
        var errText = await response.text();
        this.log('ERROR', 'Walkie sessions_send failed: ' + response.status + ' ' + errText);
        this.sendWalkieResponse(requestId, null, 'Failed to reach the agent.');
        return;
      }

      var result = await response.json();

      // Extract reply (same logic as deep tool)
      var reply = '';
      if (result.result && result.result.details && result.result.details.reply) {
        reply = result.result.details.reply;
      } else if (result.result && result.result.content) {
        var content = result.result.content;
        if (Array.isArray(content) && content[0] && content[0].text) {
          try {
            var parsed = JSON.parse(content[0].text);
            reply = parsed.reply || '';
          } catch (e) {
            reply = content[0].text;
          }
        }
      }

      if (!reply || reply === 'HEARTBEAT_OK') {
        reply = 'Done.';
      }

      var cleanedReply = this.cleanForVoice(reply);
      this.sendWalkieResponse(requestId, cleanedReply, null);
      this.log('INFO', 'Walkie complete [' + requestId + ']: ' + cleanedReply.substring(0, 100));

    } catch (err) {
      this.log('ERROR', 'Walkie request failed: ' + err.message);
      this.sendWalkieResponse(requestId, null, 'Request failed: ' + err.message);
    }
  }

  sendWalkieResponse(requestId, reply, error) {
    if (this.ws && this.ws.readyState === 1) {
      this.ws.send(JSON.stringify({
        type: 'walkie_response',
        request_id: requestId,
        reply: reply,
        error: error || undefined
      }));
    }
  }

  async triggerTestApproval() {
    return this.requestApproval('Test notification from voice call', { timeout: 60 });
  }

  /**
   * Request approval via HTTP and wait for WebSocket response (instant)
   * Falls back to polling if WebSocket notification doesn't arrive
   */
  async requestApproval(action, options = {}) {
    const timeout = options.timeout || 60;
    const details = options.details || null;
    const biometric = options.biometric || false;
    
    try {
      this.log('INFO', 'Requesting approval: ' + action);
      
      // Create approval request via HTTP
      const response = await fetch(this.baseUrl + '/v1/approvals', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.apiKey
        },
        body: JSON.stringify({
          action: action,
          details: details,
          require_biometric: biometric,
          expires_in: timeout
        })
      });
      
      if (!response.ok) {
        const errText = await response.text();
        this.log('ERROR', 'Approval request failed: ' + response.status + ' ' + errText);
        return 'Failed to send approval request.';
      }
      
      const result = await response.json();
      const requestId = result.request_id;
      const devicesNotified = result.devices_notified || 0;
      
      const devicesFailed = result.devices_failed || 0;
      
      this.log('INFO', 'Approval created: ' + requestId + ' (notified: ' + devicesNotified + ', failed: ' + devicesFailed + ')');
      
      if (devicesNotified === 0) {
        if (devicesFailed > 0) {
          return 'no_devices_reached';
        }
        return 'no_devices';
      }
      
      // Wait for WebSocket notification (with timeout fallback)
      const decision = await this.waitForApproval(requestId, timeout * 1000);
      
      this.log('INFO', 'Approval result: ' + decision);
      
      if (decision === 'approved') {
        return 'approved';
      } else if (decision === 'denied') {
        return 'denied';
      } else if (decision === 'timeout' || decision === 'expired') {
        return 'timeout';
      } else {
        return 'Approval result: ' + decision;
      }
    } catch (err) {
      this.log('ERROR', 'Approval request failed: ' + err.message);
      return 'Failed to send approval request. Error: ' + err.message;
    }
  }

  /**
   * Wait for approval response via WebSocket (instant) or polling (fallback)
   */
  waitForApproval(requestId, timeoutMs) {
    var self = this;
    
    return new Promise(function(resolve) {
      // Set up timeout
      var timeoutId = setTimeout(function() {
        self.pendingApprovals.delete(requestId);
        resolve('timeout');
      }, timeoutMs);
      
      // Register pending approval for WebSocket notification
      self.pendingApprovals.set(requestId, {
        resolve: resolve,
        timeout: timeoutId
      });
      
      // Also poll as fallback (WebSocket might miss it)
      self.pollApprovalStatus(requestId, resolve, timeoutId);
    });
  }

  /**
   * Poll approval status as fallback (in case WebSocket misses the event)
   */
  async pollApprovalStatus(requestId, resolve, timeoutId) {
    const pollInterval = 1000; // 1 second
    
    const poll = async () => {
      // Check if already resolved via WebSocket
      if (!this.pendingApprovals.has(requestId)) {
        return; // Already resolved
      }
      
      try {
        const response = await fetch(this.baseUrl + '/v1/approvals/' + requestId, {
          headers: { 'Authorization': 'Bearer ' + this.apiKey }
        });
        
        if (response.ok) {
          const result = await response.json();
          if (result.status !== 'pending') {
            // Resolved! Clear and return
            clearTimeout(timeoutId);
            this.pendingApprovals.delete(requestId);
            resolve(result.status);
            return;
          }
        }
      } catch (err) {
        this.log('WARN', 'Approval poll failed: ' + err.message);
      }
      
      // Still pending, poll again
      if (this.pendingApprovals.has(requestId)) {
        setTimeout(() => poll(), pollInterval);
      }
    };
    
    // Start polling after a short delay (give WebSocket a chance first)
    setTimeout(() => poll(), 500);
  }

  sendDeepToolProgress(requestId, text) {
    if (!this.ws || this.ws.readyState !== 1) return;
    try {
      this.ws.send(JSON.stringify({
        type: 'deep_tool_progress',
        request_id: requestId,
        text: text
      }));
    } catch (err) {
      this.log('ERROR', 'Failed to send deep tool progress: ' + err.message);
    }
  }

  sendDeepToolResult(requestId, text) {
    if (!this.ws || this.ws.readyState !== 1) return;
    try {
      this.ws.send(JSON.stringify({
        type: 'deep_tool_result',
        request_id: requestId,
        text: text
      }));
    } catch (err) {
      this.log('ERROR', 'Failed to send deep tool result: ' + err.message);
    }
  }

  // ── SMS Handler ─────────────────────────────────────────────

  async handleInboundSms(fromNumber, body, messageId) {
    try {
      // Route SMS to main session via sessions_send
      var smsPrefix = '[SMS from ' + fromNumber + '] Reply concisely (under 300 chars). No markdown. ';
      
      var mainSessionKey = 'agent:' + this.mainAgentId + ':main';
      
      var response = await fetch(this.gatewayToolsUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.gatewayToken
        },
        body: JSON.stringify({
          tool: 'sessions_send',
          args: {
            sessionKey: mainSessionKey,
            message: smsPrefix + body,
            timeoutSeconds: 60
          }
        }),
        signal: AbortSignal.timeout(90000)
      });
      
      if (!response.ok) {
        this.log('ERROR', 'SMS agent request failed: ' + response.status);
        return;
      }
      
      var result = await response.json();
      var reply = result.result || result.response || '';
      
      if (!reply) {
        this.log('WARN', 'No reply from agent for SMS');
        return;
      }
      
      // Truncate reply for SMS
      if (reply.length > 1500) {
        reply = reply.substring(0, 1497) + '...';
      }
      
      this.log('INFO', 'SMS reply: ' + reply.substring(0, 50) + '...');
      
      // Send reply via ClawdTalk API
      var sendResponse = await fetch(this.baseUrl + '/v1/messages/send', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.apiKey
        },
        body: JSON.stringify({
          to: fromNumber,
          message: reply
        })
      });
      
      if (sendResponse.ok) {
        this.log('INFO', 'SMS reply sent to ' + fromNumber.substring(0, 6) + '***');
      } else {
        var errText = await sendResponse.text();
        this.log('ERROR', 'Failed to send SMS reply: ' + errText);
      }
    } catch (err) {
      if (err.name === 'TimeoutError') {
        this.log('WARN', 'SMS agent timed out');
      } else {
        this.log('ERROR', 'SMS handler error: ' + err.message);
      }
    }
  }

  // ── TTS Helpers ─────────────────────────────────────────────

  cleanForVoice(text) {
    if (!text) return '';
    
    // Filter JSON tool call attempts
    var stripped = text.trim();
    if (stripped.startsWith('{') && stripped.endsWith('}')) {
      try {
        var parsed = JSON.parse(stripped);
        if (parsed.name || parsed.function || parsed.tool_call || parsed.arguments) {
          this.log('WARN', 'Filtered JSON from TTS');
          return "Done.";
        }
      } catch (e) {}
    }

    return text
      .replace(/[*_~`#>]/g, '')
      .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
      .replace(/\n{2,}/g, '. ')
      .replace(/\n/g, ' ')
      .replace(/\s{2,}/g, ' ')
      .replace(/[^\x00-\x7F\u00C0-\u024F\u1E00-\u1EFF]/g, '')
      .trim();
  }

  async sendResponse(callId, text) {
    if (!this.conversations.has(callId)) return;
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    try {
      this.ws.send(JSON.stringify({ type: 'response', call_id: callId, text: text.substring(0, 2000) }));
    } catch (err) {
      this.log('ERROR', 'Send failed: ' + err.message);
    }
  }

  /**
   * Report call outcome to user via gateway sessions_send
   * Routes to the main persistent session instead of creating ephemeral sessions
   */
  async reportCallOutcome(callEvent) {
    if (!this.gatewayToken) {
      this.log('DEBUG', 'No gateway configured, skipping call report');
      return;
    }
    
    var direction = callEvent.direction || 'unknown';
    var duration = callEvent.duration_seconds || 0;
    var reason = callEvent.reason || 'unknown';
    var outcome = callEvent.outcome;
    var toNumber = callEvent.to_number;
    var purpose = callEvent.purpose || callEvent.greeting;
    var voicemailMessage = callEvent.voicemail_message;
    
    // Build human-readable summary
    var summary = '';
    var emoji = '📞';
    
    if (direction === 'outbound') {
      var target = toNumber ? toNumber.replace(/(\+\d{1})(\d{3})(\d{3})(\d{4})/, '$1 ($2) $3-$4') : 'unknown number';
      
      if (outcome === 'voicemail') {
        emoji = '📬';
        summary = emoji + ' **Voicemail left** for ' + target;
        if (voicemailMessage) {
          summary += '\n> "' + voicemailMessage.substring(0, 200) + (voicemailMessage.length > 200 ? '...' : '') + '"';
        }
      } else if (outcome === 'voicemail_failed') {
        emoji = '📵';
        summary = emoji + ' Call to ' + target + ' went to voicemail but couldn\'t leave message (no beep detected)';
      } else if (outcome === 'no_answer' || reason === 'amd_silence') {
        emoji = '📵';
        summary = emoji + ' Call to ' + target + ' - no answer (silence detected)';
      } else if (outcome === 'fax') {
        emoji = '📠';
        summary = emoji + ' Call to ' + target + ' - fax machine detected, call ended';
      } else if (reason === 'user_hangup') {
        emoji = '✅';
        summary = emoji + ' Call to ' + target + ' completed (' + this.formatDuration(duration) + ')';
      } else {
        summary = emoji + ' Call to ' + target + ' ended: ' + reason + ' (' + this.formatDuration(duration) + ')';
      }
      
      if (purpose && outcome !== 'voicemail') {
        summary += '\n📋 Purpose: ' + purpose.substring(0, 100);
      }
    } else if (direction === 'inbound') {
      summary = emoji + ' Inbound call ended (' + this.formatDuration(duration) + ')';
    } else {
      summary = emoji + ' Call ended: ' + reason;
    }
    
    try {
      var response = await fetch(this.gatewayToolsUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.gatewayToken
        },
        body: JSON.stringify({
          tool: 'sessions_send',
          args: {
            sessionKey: 'agent:main:main',  // Route to main persistent session
            message: '[ClawdTalk] ' + summary,
            timeoutSeconds: 0  // Fire and forget
          }
        })
      });
      
      if (response.ok) {
        this.log('INFO', 'Call outcome reported to user (via sessions_send)');
      } else {
        var errText = await response.text().catch(function() { return ''; });
        this.log('WARN', 'Failed to report call outcome: ' + response.status + ' ' + errText);
      }
    } catch (err) {
      this.log('ERROR', 'Failed to report call outcome: ' + err.message);
    }
  }
  
  formatDuration(seconds) {
    if (!seconds || seconds < 1) return '0s';
    if (seconds < 60) return seconds + 's';
    var mins = Math.floor(seconds / 60);
    var secs = seconds % 60;
    return mins + 'm ' + secs + 's';
  }

  // ── Connection Management ───────────────────────────────────

  onClose(code) {
    var closeReason = code === 4000 ? ' ← Server killing connection (duplicate client?)' : '';
    this.log('WARN', 'WS closed: ' + code + closeReason);
    this.stopPing();
    
    // Track consecutive 4000 errors (duplicate client kicks)
    if (code === 4000) {
      this.duplicateKickCount = (this.duplicateKickCount || 0) + 1;
      
      if (this.duplicateKickCount >= 3) {
        this.log('ERROR', '════════════════════════════════════════════════════════════════');
        this.log('ERROR', 'DUPLICATE CLIENT DETECTED!');
        this.log('ERROR', '');
        this.log('ERROR', 'Another ClawdTalk client is running with the same API key.');
        this.log('ERROR', 'Each connection kicks the other off, causing this loop.');
        this.log('ERROR', '');
        this.log('ERROR', 'To fix:');
        this.log('ERROR', '  1. Find and kill all other ws-client processes:');
        this.log('ERROR', '     pkill -f "ws-client.js" && pkill -f "connect.sh"');
        this.log('ERROR', '  2. Or check other machines/containers using this API key');
        this.log('ERROR', '  3. Then restart: ./scripts/connect.sh start');
        this.log('ERROR', '════════════════════════════════════════════════════════════════');
        
        // Stop reconnecting - let user fix it
        this.isShuttingDown = true;
        process.exit(1);
      }
    } else {
      // Reset counter on non-4000 close
      this.duplicateKickCount = 0;
    }
    
    if (!this.isShuttingDown) this.scheduleReconnect();
  }

  startPing() {
    this.stopPing();
    this.pingTimer = setInterval(function() {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.ping();
        this.pongTimeout = setTimeout(function() { this.ws.terminate(); }.bind(this), 10000);
      }
    }.bind(this), 30000);
  }

  stopPing() {
    if (this.pingTimer) { clearInterval(this.pingTimer); this.pingTimer = null; }
    if (this.pongTimeout) { clearTimeout(this.pongTimeout); this.pongTimeout = null; }
  }

  scheduleReconnect() {
    if (this.isShuttingDown || this.reconnectTimer) return;
    
    var delay = this.currentReconnectDelay;
    this.reconnectAttempts++;
    this.currentReconnectDelay = Math.min(this.currentReconnectDelay * 2, RECONNECT_DELAY_MAX);
    
    this.log('INFO', 'Reconnecting in ' + (delay / 1000) + 's (attempt ' + this.reconnectAttempts + ')');
    
    this.reconnectTimer = setTimeout(function() {
      this.reconnectTimer = null;
      this.connect();
    }.bind(this), delay);
  }

  shutdown(signal) {
    this.log('INFO', 'Shutting down (' + (signal || '?') + ')');
    this.isShuttingDown = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.stopPing();
    if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.close(1000);
    process.exit(0);
  }

  // ── Start ───────────────────────────────────────────────────

  start() {
    this.log('INFO', '═══════════════════════════════════════════════');
    this.log('INFO', 'ClawdTalk WebSocket Client v1.3.0');
    this.log('INFO', 'Full agentic mode with main session routing');
    this.log('INFO', '═══════════════════════════════════════════════');
    this.log('INFO', 'Tools endpoint: ' + this.gatewayToolsUrl);
    this.log('INFO', 'Main agent: ' + this.mainAgentId);
    this.connect();
  }
}

async function ensureDeps() {
  try { require('ws'); } catch (e) {
    require('child_process').execSync('cd ' + SKILL_DIR + ' && npm install ws@8', { stdio: 'inherit' });
  }
}

async function main() { 
  await ensureDeps(); 
  new ClawdTalkClient().start(); 
}

if (require.main === module) main().catch(function(e) { console.error(e); process.exit(1); });
module.exports = ClawdTalkClient;
