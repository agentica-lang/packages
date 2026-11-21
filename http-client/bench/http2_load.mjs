import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { once } from 'node:events'
import { createServer as createHttp1 } from 'node:http'
import { createServer as createHttp2 } from 'node:http2'
import { setTimeout as sleep } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const run = promisify(execFile)
const [countArg = '1000', concurrencyArg = '48', delayArg = '0', roundsArg = '3'] = process.argv.slice(2)
const count = integer(countArg, 2, 'request count')
const concurrency = integer(concurrencyArg, 2, 'concurrency')
const delay = integer(delayArg, 0, 'server delay')
const rounds = integer(roundsArg, 1, 'rounds')
const streamLimit = 16
const chunk = 'x'.repeat(98_304)
const cases = [
  { label: 'HTTP/1.1, 1 socket', protocol: 'h1', pool: 1 },
  { label: 'HTTP/2, 1 socket', protocol: 'h2', pool: 1 },
  { label: 'HTTP/1.1, up to 16 sockets', protocol: 'h1', pool: streamLimit },
]

console.log(`Node ${process.version}, ${count} requests per case, ${concurrency} client tasks, ${delay} ms server delay`)
try {
  const results = cases.map(() => [])
  for (let round = 0; round < rounds; round++) {
    for (let offset = 0; offset < cases.length; offset++) {
      const index = (round + offset) % cases.length
      const test = cases[index]
      const sample = await measure(test)
      results[index].push(sample)
      console.log(`Round ${round + 1} | ${test.label} | ${sample.ms} ms | p95 ${sample.p95} ms | ${sample.connections} sockets | ${sample.peak} in flight`)
    }
  }

  console.table(cases.map((test, i) => ({
    case: test.label,
    'median ms': median(results[i].map(({ ms }) => ms)),
    'requests/s': Math.round(count * 1000 / median(results[i].map(({ ms }) => ms))),
    'median p95 ms': median(results[i].map(({ p95 }) => p95)),
  })))
} catch (error) {
  console.error(error.stderr?.trim() || error.message)
  process.exitCode = 1
}

async function measure(test) {
  const sockets = new Set()
  const seen = new Set()
  let connections = 0
  let active = 0
  let peak = 0
  let firstError

  const server = test.protocol === 'h2'
    ? createHttp2({ settings: { maxConcurrentStreams: streamLimit } })
    : createHttp1((request, response) => {
      handle(request.url, request.method, request, response, body => {
        response.setHeader('content-length', body.length)
        response.end(body)
      })
    })

  if (test.protocol === 'h2') {
    server.on('stream', (stream, headers) => {
      handle(headers[':path'], headers[':method'], stream, stream, body => {
        stream.respond({ ':status': 200, 'content-length': body.length })
        stream.end(body)
      })
    })
  }

  server.on('connection', socket => {
    connections++
    sockets.add(socket)
    socket.once('close', () => sockets.delete(socket))
  })
  server.on('sessionError', recordError)
  server.on('clientError', (error, socket) => {
    recordError(error)
    socket.destroy()
  })
  server.on('error', recordError)

  try {
    server.listen(0, '127.0.0.1')
    await once(server, 'listening')
    const url = `http://127.0.0.1:${server.address().port}`
    const args = ['bench/http2_load.agc', url, count, concurrency, test.protocol, test.pool].map(String)
    const { stdout } = await run(process.env.AGENTICA ?? 'agentica', args, {
      cwd: fileURLToPath(new URL('..', import.meta.url)),
      timeout: 75_000,
      killSignal: 'SIGKILL',
    })
    if (firstError) throw firstError
    assert.equal(seen.size, count, 'every request should reach Node once')
    assert(connections > 0 && connections <= test.pool, `unexpected number of sockets: ${connections}`)
    const limit = test.protocol === 'h2' ? streamLimit : test.pool
    assert(peak <= limit, `unexpected peak of ${peak} against a limit of ${limit}`)
    assert(test.protocol !== 'h2' || peak > 1, 'HTTP/2 did not multiplex requests')
    assert.match(stdout.trim(), /^\d+ \d+$/)
    const [ms, p95] = stdout.trim().split(' ').map(Number)
    return { ms, p95, connections, peak }
  } catch (error) {
    throw firstError ?? error
  } finally {
    for (const socket of sockets) socket.destroy()
    await new Promise(resolve => server.close(resolve))
  }

  function handle(path, method, request, response, send) {
    active++
    peak = Math.max(peak, active)
    response.once('close', () => active--)
    response.on('error', recordError)
    void bodyFor(path, method, request, seen).then(send).catch(error => {
      recordError(error)
      response.destroy()
    })
  }

  function recordError(error) {
    firstError ??= error
  }
}

async function bodyFor(path, method, request, seen) {
  assert.match(path, /^\/\d+$/)
  const id = Number(path.slice(1))
  assert(id >= 0 && id < count && !seen.has(id), `unexpected or duplicate request ${path}`)
  seen.add(id)

  const expected = Buffer.from(id % 3 === 0 ? `${id}:` : `${id}:${chunk}`)
  if (id % 3 === 2) {
    assert.equal(method, 'POST')
    const parts = []
    for await (const part of request) parts.push(part)
    assert(Buffer.concat(parts).equals(expected), `incorrect upload for request ${id}`)
  } else {
    assert.equal(method, 'GET')
  }

  if (delay > 0) await sleep(delay)
  return expected
}

function integer(value, minimum, name) {
  const number = Number(value)
  assert(Number.isSafeInteger(number) && number >= minimum, `${name} must be an integer of at least ${minimum}`)
  return number
}

function median(samples) {
  const ordered = samples.toSorted((a, b) => a - b)
  const mid = Math.floor(ordered.length / 2)
  return ordered.length % 2 === 0 ? (ordered[mid - 1] + ordered[mid]) / 2 : ordered[mid]
}
