import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { once } from 'node:events'
import { createServer } from 'node:http2'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const [countArg = '1000', concurrencyArg = '48'] = process.argv.slice(2)
const count = Number(countArg)
const concurrency = Number(concurrencyArg)
assert(Number.isSafeInteger(count) && count >= 2, 'request count must be an integer of at least 2')
assert(Number.isSafeInteger(concurrency) && concurrency >= 2, 'concurrency must be an integer of at least 2')

const maxConcurrentStreams = 16
const chunk = 'x'.repeat(98_304)
const sessions = new Set()
const seen = new Set()
let connections = 0
let active = 0
let peak = 0
let firstError

const server = createServer({ settings: { maxConcurrentStreams } })
server.on('session', (session) => {
  connections++
  sessions.add(session)
  session.on('error', recordError)
  session.once('close', () => sessions.delete(session))
})
server.on('sessionError', recordError)
server.on('stream', (stream, headers) => {
  active++
  peak = Math.max(peak, active)
  stream.on('error', recordError)
  stream.once('close', () => active--)

  void respond(stream, headers).catch((error) => {
    recordError(error)
    stream.destroy()
  })
})

try {
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const { stdout, stderr } = await promisify(execFile)(
    process.env.AGENTICA ?? 'agentica',
    ['bench/http2_load.agc', `http://127.0.0.1:${server.address().port}`, String(count), String(concurrency)],
    { cwd: fileURLToPath(new URL('..', import.meta.url)), timeout: 75_000, killSignal: 'SIGKILL' },
  )
  process.stdout.write(stdout)
  process.stderr.write(stderr)
  if (firstError) throw firstError
  assert.equal(seen.size, count, 'every request should reach Node once')
  assert.equal(connections, 1, 'requests should reuse one HTTP/2 session')
  assert(peak > 1 && peak <= maxConcurrentStreams, `unexpected peak of ${peak} concurrent streams`)
  console.log(`Node ${process.version} served ${seen.size} requests on ${connections} session with ${peak}/${maxConcurrentStreams} peak streams`)
} catch (error) {
  if (error.stdout) process.stdout.write(error.stdout)
  console.error(error.stderr?.trim() || error.message)
  if (firstError && firstError !== error) console.error(firstError.message)
  process.exitCode = 1
} finally {
  for (const session of sessions) session.destroy()
  server.close()
}

function recordError(error) {
  firstError ??= error
}

async function respond(stream, headers) {
  const path = headers[':path']
  assert.match(path, /^\/\d+$/)
  const id = Number(path.slice(1))
  assert(id >= 0 && id < count && !seen.has(id), `unexpected or duplicate request ${path}`)
  seen.add(id)

  const expected = Buffer.from(id % 3 === 0 ? `${id}:` : `${id}:${chunk}`)
  if (id % 3 === 2) {
    assert.equal(headers[':method'], 'POST')
    const parts = []
    for await (const part of stream) parts.push(part)
    assert(Buffer.concat(parts).equals(expected), `incorrect upload for request ${id}`)
  } else {
    assert.equal(headers[':method'], 'GET')
  }

  stream.respond({ ':status': 200, 'content-length': expected.length })
  stream.end(expected)
}
