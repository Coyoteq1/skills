#!/usr/bin/env node

import fs from 'node:fs'
import { randomUUID } from 'node:crypto'
import { createServer } from 'node:http'
import { stdin, stdout, stderr, env } from 'node:process'

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'

const MAX_MESSAGE_BYTES = Number(env.CODEX_SHIM_MAX_MESSAGE_BYTES ?? 8 * 1024 * 1024)
const TOOL_TIMEOUT_MS = Number(env.CODEX_SHIM_TOOL_TIMEOUT_MS ?? 30_000)
const MCP_PORT = Number(env.CODEX_MCP_PORT ?? 8787)
const MCP_HOST = env.CODEX_MCP_HOST ?? '127.0.0.1'
const MCP_AUTH_TOKEN = env.CODEX_MCP_AUTH_TOKEN
const CODEX_CLIENT_ID = env.CODEX_CLIENT_ID
const TOOL_SCHEMAS_PATH = env.CODEX_TOOL_SCHEMAS_PATH
const MCP_ALLOWED_ORIGINS = env.CODEX_MCP_ALLOWED_ORIGINS
  ? env.CODEX_MCP_ALLOWED_ORIGINS.split(',').map((value) => value.trim()).filter(Boolean)
  : []

/** @typedef {null | boolean | number | string | Json[] | { [k: string]: Json }} Json */

/**
 * @typedef {{
 *   request: { tool: string, args: Json, clientId: string, timeoutMs: number },
 *   resolve: (value: { content: Json, isError: boolean }) => void,
 *   reject: (reason: Error) => void,
 *   timeoutId: NodeJS.Timeout
 * }} PendingToolRequest
 */

/** @type {Buffer} */
let nativeBuffer = Buffer.alloc(0)
/** @type {PendingToolRequest | null} */
let inFlight = null
/** @type {PendingToolRequest[]} */
const queue = []

function log(message, extra) {
  const payload = extra ? `${message} ${JSON.stringify(extra)}` : message
  stderr.write(`[standalone-mcp-shim] ${payload}\n`)
}

function writeNativeMessage(msg) {
  const json = Buffer.from(JSON.stringify(msg), 'utf8')
  const header = Buffer.alloc(4)
  header.writeUInt32LE(json.length, 0)
  stdout.write(Buffer.concat([header, json]))
}

function dispatch(entry) {
  writeNativeMessage({
    type: 'tool_request',
    method: 'execute_tool',
    params: {
      tool: entry.request.tool,
      args: entry.request.args,
      client_id: entry.request.clientId,
    },
  })
}

function dispatchNext() {
  const next = queue.shift() ?? null
  if (!next) return
  inFlight = next
  dispatch(next)
}

function failInFlight(error) {
  if (!inFlight) return
  const entry = inFlight
  clearTimeout(entry.timeoutId)
  inFlight = null
  entry.reject(error)
  dispatchNext()
}

/**
 * @param {string} tool
 * @param {Json} args
 * @param {string} clientId
 * @param {number=} timeoutMs
 * @returns {Promise<{content: Json, isError: boolean}>}
 */
function sendToolRequest(tool, args, clientId, timeoutMs = TOOL_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    const timeoutId = setTimeout(() => {
      failInFlight(new Error(`Tool request timed out after ${timeoutMs}ms`))
    }, timeoutMs)

    const entry = {
      request: { tool, args, clientId, timeoutMs },
      resolve,
      reject,
      timeoutId,
    }

    if (inFlight) {
      queue.push(entry)
      return
    }
    inFlight = entry
    dispatch(entry)
  })
}

function handleToolResponse(msg) {
  if (!inFlight) {
    log('tool_response without pending request', msg)
    return
  }
  const entry = inFlight
  clearTimeout(entry.timeoutId)
  inFlight = null
  const isError = Boolean(msg.error)
  const content = msg.error?.content ?? msg.result?.content ?? null
  entry.resolve({ content, isError })
  dispatchNext()
}

function handleNativeMessage(msg) {
  switch (msg?.type) {
    case 'ping':
      writeNativeMessage({ type: 'pong' })
      return
    case 'get_status':
      writeNativeMessage({ type: 'status_response', status: { ok: true, version: 'standalone' } })
      return
    case 'tool_response':
      handleToolResponse(msg)
      return
    case 'notification':
      return
    default:
      log('unexpected native message', msg)
      return
  }
}

/**
 * @param {Buffer} chunk
 */
function onNativeData(chunk) {
  nativeBuffer = Buffer.concat([nativeBuffer, chunk])
  while (nativeBuffer.length >= 4) {
    const length = nativeBuffer.readUInt32LE(0)
    if (length > MAX_MESSAGE_BYTES) {
      log('native message length exceeds max', { length, max: MAX_MESSAGE_BYTES })
      nativeBuffer = Buffer.alloc(0)
      return
    }
    if (nativeBuffer.length < 4 + length) return
    const payload = nativeBuffer.subarray(4, 4 + length)
    nativeBuffer = nativeBuffer.subarray(4 + length)
    try {
      const msg = JSON.parse(payload.toString('utf8'))
      handleNativeMessage(msg)
    } catch (error) {
      log('invalid native JSON payload', { error: String(error) })
    }
  }
}

/**
 * @returns {Array<{name: string, description: string, inputSchema: Record<string, unknown>}>}
 */
function loadToolSchemas() {
  if (!TOOL_SCHEMAS_PATH) {
    throw new Error('Missing CODEX_TOOL_SCHEMAS_PATH env var')
  }
  const raw = fs.readFileSync(TOOL_SCHEMAS_PATH, 'utf8')
  const parsed = JSON.parse(raw)
  if (!Array.isArray(parsed)) {
    throw new Error(`Invalid tool schema file at ${TOOL_SCHEMAS_PATH}: expected array`)
  }
  return parsed
}

function extractImageContent(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null
  const base64Image = typeof payload.base64Image === 'string' ? payload.base64Image : undefined
  if (!base64Image) return null
  if (base64Image.startsWith('data:')) {
    const match = base64Image.match(/^data:(.*?);base64,(.*)$/)
    if (match) {
      return { mimeType: match[1] || 'image/png', data: match[2] || '' }
    }
  }
  return { mimeType: 'image/png', data: base64Image }
}

function formatToolResult(response) {
  const text = typeof response.content === 'string' ? response.content : JSON.stringify(response.content ?? null)
  const structuredContent =
    typeof response.content === 'object' && response.content !== null && !Array.isArray(response.content)
      ? response.content
      : undefined
  const content = [{ type: 'text', text }]
  const image = extractImageContent(structuredContent)
  if (image) {
    content.push({ type: 'image', data: image.data, mimeType: image.mimeType })
  }
  return { content, structuredContent, isError: response.isError }
}

function isLoopback(address) {
  if (!address) return false
  return address === '::1' || address === '127.0.0.1' || address.startsWith('::ffff:127.')
}

function isAllowedOrigin(origin, allowlist) {
  try {
    const url = new URL(origin)
    if (allowlist.length === 0) return isLoopback(url.hostname)
    return allowlist.includes(origin)
  } catch {
    return false
  }
}

function matchesBearerToken(value, expected) {
  const [scheme, token] = value.split(' ')
  if (!scheme || !token) return false
  if (scheme.toLowerCase() !== 'bearer') return false
  return token === expected
}

function getSessionIdHeader(value) {
  if (typeof value === 'string' && value.trim()) return value.trim()
  if (Array.isArray(value)) {
    for (const item of value) {
      if (typeof item === 'string' && item.trim()) return item.trim()
    }
  }
  return undefined
}

async function main() {
  stdin.on('data', onNativeData)
  stdin.on('error', (error) => log('stdin error', { error: String(error) }))
  stdout.on('error', (error) => log('stdout error', { error: String(error) }))

  const transports = new Map()

  function createMcpServer() {
    const server = new Server(
      { name: 'codex-extension-standalone-shim', version: '0.1.0' },
      { capabilities: { tools: { listChanged: true } } },
    )

    server.setRequestHandler(ListToolsRequestSchema, async () => {
      const tools = loadToolSchemas().map((tool) => ({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
      }))
      return { tools }
    })

    server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
      const toolName = request.params.name
      const args = request.params.arguments ?? {}
      const clientId = extra.sessionId ?? CODEX_CLIENT_ID ?? 'codex-mcp'
      try {
        const response = await sendToolRequest(toolName, /** @type {Json} */ (args), clientId)
        return formatToolResult(response)
      } catch (error) {
        return formatToolResult({ content: { error: String(error) }, isError: true })
      }
    })

    return server
  }

  /** @returns {Promise<StreamableHTTPServerTransport>} */
  async function createSessionTransport() {
    const mcpServer = createMcpServer()
    let transport
    transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (sessionId) => {
        transports.set(sessionId, transport)
      },
    })
    transport.onclose = () => {
      const sid = transport.sessionId
      if (sid) transports.delete(sid)
    }
    await mcpServer.connect(transport)
    return transport
  }

  const httpServer = createServer(async (req, res) => {
    const requestUrl = new URL(req.url ?? '/', `http://${MCP_HOST}`)
    if (requestUrl.pathname !== '/mcp') {
      res.statusCode = 404
      res.end('Not Found')
      return
    }
    if (!isLoopback(req.socket.remoteAddress)) {
      res.statusCode = 403
      res.end('Forbidden')
      return
    }
    const origin = req.headers.origin
    if (origin && !isAllowedOrigin(origin, MCP_ALLOWED_ORIGINS)) {
      res.statusCode = 403
      res.end('Forbidden')
      return
    }
    if (MCP_AUTH_TOKEN) {
      const auth = req.headers.authorization ?? ''
      if (!matchesBearerToken(auth, MCP_AUTH_TOKEN)) {
        res.statusCode = 401
        res.end('Unauthorized')
        return
      }
    }

    const method = req.method ?? 'GET'
    const sessionId = getSessionIdHeader(req.headers['mcp-session-id'])

    if (method === 'POST') {
      if (sessionId) {
        const existing = transports.get(sessionId)
        if (!existing) {
          res.statusCode = 404
          res.end('Not Found')
          return
        }
        await existing.handleRequest(req, res)
        return
      }
      const transport = await createSessionTransport()
      await transport.handleRequest(req, res)
      if (!transport.sessionId) {
        await transport.close().catch(() => {})
      }
      return
    }

    if (method === 'GET' || method === 'DELETE') {
      if (!sessionId) {
        res.statusCode = 400
        res.end('Bad Request')
        return
      }
      const existing = transports.get(sessionId)
      if (!existing) {
        res.statusCode = 404
        res.end('Not Found')
        return
      }
      await existing.handleRequest(req, res)
      return
    }

    res.statusCode = 405
    res.end('Method Not Allowed')
  })

  await new Promise((resolve) => {
    httpServer.listen(MCP_PORT, MCP_HOST, resolve)
  })
  log('shim started', { host: MCP_HOST, port: MCP_PORT, schemas: TOOL_SCHEMAS_PATH })
}

main().catch((error) => {
  log('fatal error', { error: String(error) })
  process.exit(1)
})
