#!/usr/bin/env node
/**
 * ClawdTalk WebSocket Client v1.2.9
 * 
 * Connects to ClawdTalk server and routes voice calls to your Clawdbot gateway.
 * Phone → STT → Gateway Agent → TTS → Phone
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

// Transcription filtering and debouncing
const MIN_TRANSCRIPT_LENGTH = 2;
const TRANSCRIPT_DEBOUNCE_MS = 300;

// Tool execution limits
const MAX_TOOL_LOOPS = 10;
const TOOL_TIMEOUT_MS = 30000;

// Gateway config paths
const CLAWDBOT_CONFIG_PATHS = [
  path.join(process.env.HOME || '/home/node', '.clawdbot', 'clawdbot.json'),
  path.join(process.env.HOME || '/home/node', '.openclaw', 'openclaw.json'),
  '/home/node/.clawdbot/clawdbot.json',
  '/home/node/.openclaw/openclaw.json',
];

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
- Don't wait until the end to summarize — drip information as you find it.`;

function loadGatewayConfig() {
  // Collect config from all paths, prioritizing ones with valid tokens
  var bestConfig = null;
  var configWithToken = null;
  
  for (var i = 0; i < CLAWDBOT_CONFIG_PATHS.length; i++) {
    try {
      if (fs.existsSync(CLAWDBOT_CONFIG_PATHS[i])) {
        var config = JSON.parse(fs.readFileSync(CLAWDBOT_CONFIG_PATHS[i], 'utf8'));
        var port = (config.gateway && config.gateway.port) || 18789;
        var token = resolveEnvVar((config.gateway && config.gateway.auth && config.gateway.auth.token) || '');
        
        // Find the main agent ID (first agent or one marked default)
        var mainAgentId = 'main';
        if (config.agents && config.agents.list && config.agents.list.length > 0) {
          var defaultAgent = config.agents.list.find(function(a) { return a.default; });
          mainAgentId = defaultAgent ? defaultAgent.id : config.agents.list[0].id;
        }
        
        var result = { 
          chatUrl: 'http://127.0.0.1:' + port + '/v1/chat/completions',
          toolsUrl: 'http://127.0.0.1:' + port + '/tools/invoke',
          token: token,
          mainAgentId: mainAgentId
        };
        
        // Keep first config as fallback
        if (!bestConfig) bestConfig = result;
        
        // If this config has a token, use it immediately
        if (token) {
          configWithToken = result;
          break;
        }
      }
    } catch (e) {}
  }
  
  // Return config with token, or best available, or defaults
  if (configWithToken) return configWithToken;
  if (bestConfig) return bestConfig;
  var defaultPort = 18789;
  return {
    chatUrl: process.env.CLAWDBOT_GATEWAY_URL || 'http://127.0.0.1:' + defaultPort + '/v1/chat/completions',
    toolsUrl: 'http://127.0.0.1:' + defaultPort + '/tools/invoke',
    token: process.env.CLAWDBOT_GATEWAY_TOKEN || '',
    mainAgentId: 'main'
  };
}

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
    this.pendingRequests = new Map();
    this.transcriptionDebounce = new Map();
    this.queuedTranscriptions = new Map();
    this.args = parseArgs();

    // Exponential backoff for reconnection
    this.reconnectAttempts = 0;
    this.currentReconnectDelay = RECONNECT_DELAY_MIN;

    // Gateway
    this.gatewayChatUrl = null;
    this.gatewayToolsUrl = null;
    this.gatewayToken = null;
    this.gatewayAgent = 'main';
    this.mainAgentId = 'main';
    this.voiceContext = DEFAULT_VOICE_CONTEXT;
    this.maxConversationTurns = 20;
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
    var gwConfig = loadGatewayConfig();
    this.gatewayChatUrl = gwConfig.chatUrl;
    this.gatewayToolsUrl = gwConfig.toolsUrl;
    this.gatewayToken = gwConfig.token;
    this.mainAgentId = gwConfig.mainAgentId;

    if (this.config.max_conversation_turns) {
      this.maxConversationTurns = this.config.max_conversation_turns;
    }
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
    this.log('INFO', 'Gateway: ' + this.gatewayChatUrl);
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
      this.log('INFO', 'Authenticated (v1.2.9 agentic mode)');
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
      var debounce = this.transcriptionDebounce.get(callId);
      if (debounce) {
        clearTimeout(debounce.timer);
        this.transcriptionDebounce.delete(callId);
      }
      this.log('INFO', 'Call ended: ' + callId);
      
      // Report call outcome to user
      this.reportCallOutcome(msg);
      return;
    }

    // Handle transcription events (could be 'message', 'transcription', or 'transcript')
    if ((event === 'message' || event === 'transcription' || event === 'transcript') && callId) {
      var text = (msg.text || msg.transcript || '').trim();
      if (!text || text.replace(/\s/g, '').length < MIN_TRANSCRIPT_LENGTH) {
        return;
      }

      this.log('INFO', 'STT [' + callId + ']: ' + text);

      var pending = this.pendingRequests.get(callId);
      if (!pending) {
        this.debounceTranscription(callId, text);
      } else {
        this.log('INFO', 'Request in-flight, queuing: ' + text);
        var existing = this.queuedTranscriptions.get(callId);
        this.queuedTranscriptions.set(callId, existing ? existing + ' ' + text : text);
      }
      return;
    }

    // Handle deep_tool_request (Voice AI asking for complex query via Clawdbot)
    if (event === 'deep_tool_request') {
      var requestId = msg.request_id;
      var callControlId = msg.call_control_id || null;
      var query = msg.query || '';
      this.log('INFO', 'Deep tool request [' + requestId + ']: ' + query.substring(0, 100));
      if (callControlId) {
        this.log('INFO', 'Call control ID: ' + callControlId);
      }
      
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

    // Log unhandled events for debugging
    if (process.env.DEBUG) {
      this.log('DEBUG', 'Unhandled event: ' + event);
    }
  }

  // ── Deep Tool Handler ───────────────────────────────────────

  async handleDeepToolRequest(callId, requestId, query, context) {
    try {
      // Route to main session via tools/invoke sessions_send - uses full agent context/memory
      var voicePrefix = '[VOICE CALL] Respond concisely for speech. No markdown, no lists, no URLs. ';
      
      // Use the main agent session - format: agent:{agentId}:main
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

  debounceTranscription(callId, text) {
    var existing = this.transcriptionDebounce.get(callId);

    if (existing) {
      clearTimeout(existing.timer);
      existing.text += ' ' + text;
    } else {
      existing = { text: text, timer: null };
      this.transcriptionDebounce.set(callId, existing);
    }

    var self = this;
    existing.timer = setTimeout(function() {
      var debounce = self.transcriptionDebounce.get(callId);
      if (debounce) {
        var finalText = debounce.text;
        self.transcriptionDebounce.delete(callId);
        self.log('INFO', 'Processing [' + callId + ']: ' + finalText);
        self.runAgentLoop(callId, finalText);
      }
    }, TRANSCRIPT_DEBOUNCE_MS);
  }

  // ── Agent Loop with Tool Execution ──────────────────────────

  async runAgentLoop(callId, userText) {
    if (!this.conversations.has(callId)) {
      this.conversations.set(callId, [
        { role: 'system', content: this.voiceContext }
      ]);
    }

    var history = this.conversations.get(callId);
    history.push({ role: 'user', content: userText });

    // Trim history
    while (history.length > this.maxConversationTurns * 2 + 1) {
      history.splice(1, 1); // Keep system message
    }

    var startTime = Date.now();
    this.pendingRequests.set(callId, true);

    // "One moment" fallback timer
    var self = this;
    var fallbackSent = false;
    var fallbackTimer = setTimeout(async function() {
      if (self.conversations.has(callId) && !fallbackSent) {
        fallbackSent = true;
        await self.sendResponse(callId, 'One moment...');
        self.log('INFO', 'Sent fallback for slow response');
      }
    }, 5000);

    try {
      var loopCount = 0;
      var finalContent = null;

      while (loopCount < MAX_TOOL_LOOPS) {
        loopCount++;
        
        // Make chat completion request (non-streaming for tool handling)
        var response = await this.chatCompletion(callId, history);
        
        if (!response) {
          this.log('ERROR', 'No response from gateway');
          finalContent = "Sorry, I couldn't process that.";
          break;
        }

        var choice = response.choices && response.choices[0];
        if (!choice) {
          this.log('ERROR', 'No choice in response');
          finalContent = "Sorry, something went wrong.";
          break;
        }

        var message = choice.message;
        
        // Check for tool calls
        if (message.tool_calls && message.tool_calls.length > 0) {
          this.log('INFO', 'Tool calls detected: ' + message.tool_calls.length);
          
          // Add assistant message with tool calls to history
          history.push({
            role: 'assistant',
            content: message.content || null,
            tool_calls: message.tool_calls
          });

          // Execute each tool call
          for (var i = 0; i < message.tool_calls.length; i++) {
            var toolCall = message.tool_calls[i];
            var toolResult = await this.executeTool(toolCall);
            
            // Add tool result to history
            history.push({
              role: 'tool',
              tool_call_id: toolCall.id,
              content: JSON.stringify(toolResult)
            });
          }
          
          // Continue loop to get final response
          continue;
        }

        // No tool calls - we have final content
        finalContent = message.content || '';
        
        // Add to history
        if (finalContent) {
          history.push({ role: 'assistant', content: finalContent });
        }
        
        break;
      }

      if (loopCount >= MAX_TOOL_LOOPS) {
        this.log('WARN', 'Max tool loops reached');
        finalContent = finalContent || "Sorry, that took too long to process.";
      }

      // Send final response as TTS
      clearTimeout(fallbackTimer);
      var cleanedResponse = this.cleanForVoice(finalContent || '');
      
      if (cleanedResponse && cleanedResponse.length > 2 && this.conversations.has(callId)) {
        await this.sendResponse(callId, cleanedResponse);
      } else if (!cleanedResponse || cleanedResponse.length <= 2) {
        this.log('WARN', 'Empty response');
        if (this.conversations.has(callId) && !fallbackSent) {
          await this.sendResponse(callId, "Sorry, I got an empty response.");
        }
      }

      var elapsed = Date.now() - startTime;
      this.log('INFO', 'Response complete (' + elapsed + 'ms, ' + loopCount + ' loop(s)) [' + callId + ']');

    } catch (err) {
      clearTimeout(fallbackTimer);
      this.log('ERROR', 'Agent loop failed: ' + err.message);
      if (this.conversations.has(callId)) {
        await this.sendResponse(callId, 'Sorry, I had trouble with that request.');
      }
    } finally {
      this.pendingRequests.delete(callId);

      // Process queued transcriptions
      if (this.queuedTranscriptions.has(callId)) {
        var queuedText = this.queuedTranscriptions.get(callId);
        this.queuedTranscriptions.delete(callId);
        if (this.conversations.has(callId)) {
          this.log('INFO', 'Processing queued: ' + queuedText);
          this.runAgentLoop(callId, queuedText);
        }
      }
    }
  }

  // ── Chat Completion (non-streaming) ─────────────────────────

  async chatCompletion(callId, messages) {
    try {
      var response = await fetch(this.gatewayChatUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.gatewayToken,
          'x-clawdbot-agent-id': this.gatewayAgent,
          'x-clawdbot-session-key': 'voice-call-' + callId,
        },
        body: JSON.stringify({
          messages: messages,
          max_tokens: 500,
          stream: false,
        }),
        signal: AbortSignal.timeout(60000),
      });

      if (!response.ok) {
        var errBody = await response.text().catch(function() { return ''; });
        this.log('ERROR', 'Gateway HTTP ' + response.status + ': ' + errBody.substring(0, 200));
        return null;
      }

      return await response.json();
    } catch (err) {
      this.log('ERROR', 'Chat completion failed: ' + err.message);
      return null;
    }
  }

  // ── Tool Execution via /tools/invoke ────────────────────────

  async executeTool(toolCall) {
    var toolName = toolCall.function.name;
    var toolArgs = {};
    
    try {
      toolArgs = JSON.parse(toolCall.function.arguments || '{}');
    } catch (e) {
      this.log('WARN', 'Failed to parse tool args: ' + e.message);
    }

    this.log('INFO', 'Executing tool: ' + toolName + ' args=' + JSON.stringify(toolArgs).substring(0, 100));

    try {
      var response = await fetch(this.gatewayToolsUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.gatewayToken,
        },
        body: JSON.stringify({
          tool: toolName,
          args: toolArgs,
          sessionKey: 'voice',
        }),
        signal: AbortSignal.timeout(TOOL_TIMEOUT_MS),
      });

      if (!response.ok) {
        var errBody = await response.text().catch(function() { return ''; });
        this.log('ERROR', 'Tool invoke HTTP ' + response.status + ': ' + errBody.substring(0, 200));
        return { ok: false, error: 'Tool execution failed: HTTP ' + response.status };
      }

      var result = await response.json();
      this.log('INFO', 'Tool result: ' + JSON.stringify(result).substring(0, 200));
      return result;
    } catch (err) {
      this.log('ERROR', 'Tool execution failed: ' + err.message);
      return { ok: false, error: 'Tool execution failed: ' + err.message };
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
    
    // Use /tools/invoke to call sessions_send tool
    // Derive tools endpoint from chat URL (replace /v1/chat/completions with /tools/invoke)
    var toolsInvokeUrl = this.gatewayChatUrl ? 
      this.gatewayChatUrl.replace('/v1/chat/completions', '/tools/invoke') :
      'http://localhost:18789/tools/invoke';
    
    try {
      var response = await fetch(toolsInvokeUrl, {
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
    this.log('INFO', 'ClawdTalk WebSocket Client v1.2.9');
    this.log('INFO', 'Full agentic mode with main session routing');
    this.log('INFO', '═══════════════════════════════════════════════');
    this.log('INFO', 'Chat endpoint: ' + this.gatewayChatUrl);
    this.log('INFO', 'Tools endpoint: ' + this.gatewayToolsUrl);
    this.log('INFO', 'Agent: ' + this.gatewayAgent);
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
