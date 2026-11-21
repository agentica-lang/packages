import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import { createServer as createHttp1 } from 'node:http'
import { createSecureServer, createServer as createHttp2 } from 'node:http2'
import { setTimeout as sleep } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const run = promisify(execFile)
const args = process.argv.slice(2)
const inference = args[0] === 'infer'
const [countArg, concurrencyArg, minArg, maxArg, roundsArg, h1Arg, h2Arg] = inference
  ? args.slice(1)
  : [args[0], args[1], args[2], args[2], args[3]]
const count = integer(countArg ?? (inference ? '240' : '1000'), 2, 'request count')
const concurrency = integer(concurrencyArg ?? (inference ? '160' : '48'), 2, 'concurrency')
const minDelay = integer(minArg ?? (inference ? '20' : '0'), 0, 'minimum server delay')
const maxDelay = integer(maxArg ?? (inference ? '80' : '0'), minDelay, 'maximum server delay')
const rounds = integer(roundsArg ?? '3', 1, 'rounds')
const streamLimit = inference ? 100 : 16
const chunk = 'x'.repeat(98_304)
const h1 = integer(h1Arg ?? '30', 1, 'HTTP/1.1 pool size')
const h2 = integer(h2Arg ?? '2', 1, 'HTTP/2 pool size')
const cases = inference ? [
  { label: `HTTP/1.1, up to ${h1} sockets`, protocol: 'h1', pool: h1 },
  { label: `HTTP/2, up to ${h2} sockets`, protocol: 'h2', pool: h2 },
] : [
  { label: 'HTTP/1.1, 1 socket', protocol: 'h1', pool: 1 },
  { label: 'HTTP/2, 1 socket', protocol: 'h2', pool: 1 },
  { label: 'HTTP/1.1, up to 16 sockets', protocol: 'h1', pool: streamLimit },
]
const capacity = Math.min(concurrency, ...cases.map(test => test.pool * (test.protocol === 'h2' ? streamLimit : 1)))
const budget = Math.max(60_000, (Math.ceil(count / capacity) + 2) * (maxDelay + 1000))
assert(budget <= 2_147_468_647, 'workload exceeds the timer range')

const profile = inference ? 'infer' : 'mixed'
console.log(`Node ${process.version}, ${profile}, ${count} requests per case, ${concurrency} client tasks, ${minDelay}–${maxDelay} ms server delay`)
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

  const medians = results.map(samples => median(samples.map(({ ms }) => ms)))
  console.table(cases.map((test, i) => ({
    case: test.label,
    'median ms': medians[i],
    'requests/s': Math.round(count * 1000 / medians[i]),
    'median p95 ms': median(results[i].map(({ p95 }) => p95)),
  })))
  console.log(`Throughput ratio HTTP/2 ÷ HTTP/1.1 (first case): ${(medians[0] / medians[1]).toFixed(2)}×`)
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

  const server = makeServer(test.protocol, handle, recordError)

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
    const origin = inference ? 'https://api.test' : 'http://127.0.0.1'
    const url = `${origin}:${server.address().port}`
    const args = ['bench/http2_load.agc', url, count, concurrency, test.protocol, test.pool, profile, budget].map(String)
    const { stdout } = await run(process.env.AGENTICA ?? 'agentica', args, {
      cwd: fileURLToPath(new URL('..', import.meta.url)),
      timeout: budget + 15_000,
      killSignal: 'SIGKILL',
    })
    if (firstError) throw firstError
    assert.equal(seen.size, count, 'every request should reach Node once')
    assert(connections > 0 && connections <= test.pool, `unexpected number of sockets: ${connections}`)
    const limit = test.protocol === 'h2' ? test.pool * streamLimit : test.pool
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
    let pending = true
    function settled() {
      if (!pending) return
      pending = false
      active--
      response.off('finish', settled)
      response.off('close', settled)
    }
    response.once('finish', settled)
    response.once('close', settled)
    response.on('error', recordError)
    void bodyFor(path, method, request, seen).then(body => {
      if (inference) settled()
      send(body)
    }).catch(error => {
      recordError(error)
      response.destroy()
    })
  }

  function recordError(error) {
    firstError ??= error
  }
}

function makeServer(protocol, handle, recordError) {
  function requestHandler(request, response) {
    const expectedVersion = protocol === 'h2' ? '2.0' : '1.1'
    if (request.httpVersion !== expectedVersion) {
      recordError(new Error(`expected HTTP/${expectedVersion}, got HTTP/${request.httpVersion}`))
      response.destroy()
      return
    }
    if (inference) request.resume()
    handle(request.url, request.method, request, response, body => {
      response.setHeader('content-length', body.length)
      response.end(body)
    })
  }

  const settings = { maxConcurrentStreams: streamLimit }
  if (inference) {
    return createSecureServer({
      allowHTTP1: true,
      cert: tlsFixture('server.pem'),
      key: tlsFixture('server.key'),
      settings,
    }, requestHandler)
  }
  if (protocol === 'h1') return createHttp1(requestHandler)

  const server = createHttp2({ settings })
  server.on('stream', (stream, headers) => {
    handle(headers[':path'], headers[':method'], stream, stream, body => {
      stream.respond({ ':status': 200, 'content-length': body.length })
      stream.end(body)
    })
  })
  return server
}

async function bodyFor(path, method, request, seen) {
  assert.match(path, inference ? /^\/infer\/\d+$/ : /^\/\d+$/)
  const id = Number(path.slice(path.lastIndexOf('/') + 1))
  assert(id >= 0 && id < count && !seen.has(id), `unexpected or duplicate request ${path}`)
  seen.add(id)

  const delay = minDelay + (Math.imul(id + 1, 0x9e3779b1) >>> 0) % (maxDelay - minDelay + 1)
  if (inference) {
    assert.equal(method, 'GET')
    if (delay > 0) await sleep(delay)
    return Buffer.from(`${id}:inference`)
  }

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

function tlsFixture(name) {
  return readFileSync(new URL(`../test/specs/fixtures/tls/${name}`, import.meta.url))
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
