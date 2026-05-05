#!/usr/bin/env node

// Protocol implementation adapted from predict-woo/kaikey-extension (MIT).
// This file intentionally has no browser-extension dependencies.

import { randomUUID, webcrypto } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const cryptoApi = globalThis.crypto || webcrypto;
const subtle = cryptoApi.subtle;

const DEFAULT_STATE_PATH = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "KLMSNotesSync",
  "kaikey_state.json"
);

class AuthProtocolError extends Error {}

const DEFAULT_OS_VERSION = "Android 15";
const DEFAULT_DEVICE_NAME = "KLMS Notes Sync";

function usage() {
  return `Usage:
  kaikey_cli.mjs status [--state PATH]
  kaikey_cli.mjs identity [--state PATH]
  kaikey_cli.mjs registration-url
  kaikey_cli.mjs register (--qr-json JSON | --qr-json-file PATH) [--state PATH]
  kaikey_cli.mjs auth-check [--state PATH]
  kaikey_cli.mjs approve-number --number NN [--state PATH]
  kaikey_cli.mjs approve-if-match --digits NN [--attempts N] [--interval-ms MS] [--state PATH]
  kaikey_cli.mjs reset [--state PATH]
`;
}

function parseArgs(argv) {
  const opts = {};
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      rest.push(arg);
      continue;
    }
    const eq = arg.indexOf("=");
    if (eq >= 0) {
      opts[arg.slice(2, eq)] = arg.slice(eq + 1);
      continue;
    }
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) {
      opts[key] = next;
      i += 1;
    } else {
      opts[key] = true;
    }
  }
  return { opts, rest };
}

function statePath(opts) {
  return String(opts.state || process.env.KAIKEY_STATE_PATH || DEFAULT_STATE_PATH);
}

function newDeviceState() {
  return {
    device_id: randomUUID(),
    push_token: "manual-cli-" + randomUUID(),
    device_nm: process.env.KAIKEY_DEVICE_NAME || DEFAULT_DEVICE_NAME,
    os_ver: process.env.KAIKEY_OS_VERSION || DEFAULT_OS_VERSION,
    sites: []
  };
}

async function loadState(filePath, create) {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    const state = JSON.parse(raw);
    if (state && state.device_id && Array.isArray(state.sites)) {
      return state;
    }
    throw new AuthProtocolError(`Invalid Kaikey state file: ${filePath}`);
  } catch (error) {
    if (error && error.code === "ENOENT" && create) {
      return newDeviceState();
    }
    throw error;
  }
}

async function saveState(filePath, state) {
  await fs.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const tmpPath = `${filePath}.tmp.${process.pid}`;
  await fs.writeFile(tmpPath, JSON.stringify(state, null, 2) + "\n", {
    mode: 0o600
  });
  await fs.rename(tmpPath, filePath);
  await fs.chmod(filePath, 0o600);
}

function selectSite(state) {
  if (!state.sites.length) {
    throw new AuthProtocolError("No registered Kaikey site. Run register first.");
  }
  return state.sites[0];
}

function publicState(state, filePath) {
  return {
    state_path: filePath,
    registered: state.sites.length > 0,
    device_nm: state.device_nm,
    os_ver: state.os_ver,
    sites: state.sites.map((site) => ({
      display_nm: site.display_nm,
      site_id: site.site_id,
      base_url: site.base_url,
      authenticator: site.authenticator,
      version: site.version,
      sln_uu_id: site.sln_uu_id
    }))
  };
}

async function readQrJson(opts) {
  if (opts["qr-json"]) {
    return String(opts["qr-json"]);
  }
  if (opts["qr-json-file"]) {
    return await fs.readFile(String(opts["qr-json-file"]), "utf8");
  }
  if (!process.stdin.isTTY) {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    const value = Buffer.concat(chunks).toString("utf8").trim();
    if (value) return value;
  }
  throw new AuthProtocolError("Missing QR JSON. Pass --qr-json or --qr-json-file.");
}

function printJson(payload) {
  process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  if (!subtle || typeof fetch !== "function") {
    throw new AuthProtocolError("This script requires Node.js with WebCrypto and fetch.");
  }

  const { opts, rest } = parseArgs(process.argv.slice(2));
  const command = rest[0] || "help";
  const filePath = statePath(opts);

  if (command === "help" || opts.help) {
    process.stdout.write(usage());
    return;
  }

  if (command === "status") {
    let state;
    try {
      state = await loadState(filePath, false);
    } catch (error) {
      if (!error || error.code !== "ENOENT") throw error;
      printJson({ state_path: filePath, registered: false, sites: [] });
      process.exitCode = 2;
      return;
    }
    const payload = publicState(state, filePath);
    printJson(payload);
    if (!payload.registered) process.exitCode = 2;
    return;
  }

  if (command === "identity") {
    const state = await loadState(filePath, false);
    const site = selectSite(state);
    process.stdout.write(`${site.display_nm}\n`);
    return;
  }

  if (command === "registration-url") {
    process.stdout.write("https://sso.kaist.ac.kr/auth/twofactor/mfa/regist/step01\n");
    return;
  }

  if (command === "register") {
    const state = await loadState(filePath, true);
    const qr = parseQrJson(await readQrJson(opts));
    const lookup = await regLookup(qr, state);
    const site = await registerSite(qr, lookup, state);
    upsertSite(state, site);
    await saveState(filePath, state);
    printJson({
      ok: true,
      state_path: filePath,
      site_id: site.site_id,
      display_nm: site.display_nm,
      sln_uu_id: site.sln_uu_id
    });
    return;
  }

  if (command === "auth-check") {
    const state = await loadState(filePath, false);
    const site = selectSite(state);
    const data = await authCheck(site, state);
    if (!data.result || !data.id_token || !data.challenge) {
      printJson({ ok: true, pending: false, errcode: data.errcode || "" });
      return;
    }
    printJson({
      ok: true,
      pending: true,
      choices: vnumberChoices(await generateVnumber(data.challenge, site.version))
    });
    return;
  }

  if (command === "approve-number") {
    const number = String(opts.number || "").trim();
    if (!/^\d{2}$/.test(number)) {
      throw new AuthProtocolError("approve-number requires --number NN.");
    }
    const state = await loadState(filePath, false);
    const site = selectSite(state);
    const data = await authCheck(site, state);
    if (!data.result || !data.id_token || !data.challenge) {
      printJson({ ok: true, approved: false, reason: "no-pending-request" });
      process.exitCode = 2;
      return;
    }
    const real = await generateVnumber(data.challenge, site.version);
    if (number !== real) {
      printJson({ ok: true, approved: false, reason: "selected-number-mismatch" });
      process.exitCode = 3;
      return;
    }
    const result = await approveAuth(site, state, data.id_token);
    if (!result.result) {
      throw new AuthProtocolError(
        `Approval failed: ${result.errcode || JSON.stringify(result)}`
      );
    }
    printJson({ ok: true, approved: true });
    return;
  }

  if (command === "approve-if-match") {
    const digits = String(opts.digits || "").trim();
    if (!/^\d{2}$/.test(digits)) {
      throw new AuthProtocolError("approve-if-match requires --digits NN.");
    }
    const attempts = Math.max(1, Number.parseInt(String(opts.attempts || "5"), 10));
    const intervalMs = Math.max(100, Number.parseInt(String(opts["interval-ms"] || "1500"), 10));
    const state = await loadState(filePath, false);
    const site = selectSite(state);

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      const data = await authCheck(site, state);
      if (!data.result || !data.id_token || !data.challenge) {
        if (attempt < attempts) {
          await sleep(intervalMs);
          continue;
        }
        printJson({ ok: true, matched: false, reason: "no-pending-request" });
        process.exitCode = 2;
        return;
      }

      const real = await generateVnumber(data.challenge, site.version);
      if (real !== digits) {
        printJson({ ok: true, matched: false, reason: "mismatch", real_number: real });
        process.exitCode = 3;
        return;
      }

      const result = await approveAuth(site, state, data.id_token);
      if (!result.result) {
        throw new AuthProtocolError(
          `Approval failed: ${result.errcode || JSON.stringify(result)}`
        );
      }
      printJson({ ok: true, matched: true, approved: true });
      return;
    }
    return;
  }

  if (command === "reset") {
    await saveState(filePath, newDeviceState());
    printJson({ ok: true, reset: true, state_path: filePath });
    return;
  }

  throw new AuthProtocolError(`Unknown command: ${command}\n${usage()}`);
}

function parseQrJson(value) {
  let payload;
  try {
    payload = JSON.parse(String(value).trim());
  } catch (error) {
    throw new AuthProtocolError(`Invalid QR JSON: ${error.message}`);
  }
  const required = [
    "display_nm",
    "site_id",
    "base_url",
    "id_token",
    "time",
    "authenticator"
  ];
  const missing = required.filter((key) => !payload?.[key]);
  if (missing.length) {
    throw new AuthProtocolError(`QR JSON is missing field(s): ${missing.join(", ")}`);
  }
  if (payload.authenticator !== "push") {
    throw new AuthProtocolError("Only the legacy push authenticator is implemented.");
  }
  if (String(payload.version || "") === "2.0") {
    throw new AuthProtocolError("version=2.0 uses FIDO UAF and is not implemented.");
  }
  return payload;
}

async function postJson(baseUrl, endpointPath, payload, timeoutMs = 20000) {
  const url = baseUrl.replace(/\/+$/, "") + "/" + endpointPath.replace(/^\/+/, "");
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json;charset=UTF-8" },
      body: JSON.stringify(payload),
      signal: ctrl.signal
    });
    if (!res.ok) throw new AuthProtocolError(`HTTP ${res.status} for ${url}`);
    const text = await res.text();
    try {
      return JSON.parse(text);
    } catch {
      throw new AuthProtocolError(`Server did not return JSON for ${url}: ${text.slice(0, 200)}`);
    }
  } finally {
    clearTimeout(timer);
  }
}

async function regLookup(qr, state) {
  const data = await postJson(qr.base_url, "api/app/regist/check", {
    device_id: state.device_id,
    id_token: qr.id_token,
    device_nm: state.device_nm,
    os_ver: state.os_ver
  });
  if (!data.result) {
    throw new AuthProtocolError(`Registration lookup failed: ${data.errcode || JSON.stringify(data)}`);
  }
  if (!data.pubkey || !data.sln_uu_id) {
    throw new AuthProtocolError(`Registration lookup missing pubkey or sln_uu_id: ${JSON.stringify(data)}`);
  }
  return data;
}

async function registerSite(qr, lookup, state) {
  const { privateHex, publicHex } = await generateEcKeypair();
  const sign = await signP1363Hex(privateHex, utf8(state.device_id + qr.id_token));
  const payload = {
    device_id: state.device_id,
    id_token: qr.id_token,
    push_token: state.push_token,
    app_pubkey: publicHex,
    device_nm: state.device_nm,
    os_ver: state.os_ver,
    authenticator: qr.authenticator,
    sign
  };
  const encrypted = await encryptForServer(payload, lookup.pubkey);
  const data = await postJson(qr.base_url, "api/app/regist", encrypted);
  if (!data.result) {
    throw new AuthProtocolError(`Registration failed: ${data.errcode || JSON.stringify(data)}`);
  }
  return {
    display_nm: qr.display_nm,
    site_id: qr.site_id,
    site_display: qr.site_id,
    base_url: qr.base_url,
    authenticator: qr.authenticator,
    version: String(qr.version || ""),
    id_token: qr.id_token,
    sln_uu_id: lookup.sln_uu_id,
    server_pubkey: lookup.pubkey,
    ecc_private_key: privateHex,
    ecc_public_key: publicHex
  };
}

function upsertSite(state, site) {
  const index = state.sites.findIndex(
    (existing) =>
      existing.site_id === site.site_id &&
      existing.sln_uu_id === site.sln_uu_id &&
      existing.authenticator === site.authenticator
  );
  if (index >= 0) {
    state.sites[index] = site;
  } else {
    state.sites.push(site);
  }
}

async function authCheck(site, state) {
  return await postJson(site.base_url, "api/app/auth/check", {
    sln_uu_id: site.sln_uu_id,
    device_id: state.device_id,
    device_nm: state.device_nm,
    os_ver: state.os_ver
  });
}

async function approveAuth(site, state, idToken) {
  const sign = await signP1363Hex(site.ecc_private_key, utf8(state.device_id + idToken));
  const payload = {
    device_id: state.device_id,
    id_token: idToken,
    authtype: "finger",
    device_nm: state.device_nm,
    os_ver: state.os_ver,
    sign
  };
  const encrypted = await encryptForServer(payload, site.server_pubkey);
  return await postJson(site.base_url, "api/app/auth", encrypted);
}

async function encryptForServer(payload, serverPubKey) {
  const envelope = randomBytes(68);
  const leaKey = envelope.slice(0, 16);
  const iv = envelope.slice(32, 48);
  const plaintext = utf8(JSON.stringify(payload));
  const padded = protocolPad(plaintext);
  return {
    E1: bytesToHex(leaCbcEncrypt(padded, leaKey, iv)),
    E2: bytesToHex(await rsaOaepSha256Encrypt(envelope, serverPubKey))
  };
}

function protocolPad(plaintext) {
  const prefix = randomBytes(10);
  const padLen = 16 - ((plaintext.length + 10) % 16);
  const tail = new Uint8Array(padLen);
  tail[padLen - 1] = padLen;
  return concatBytes(prefix, plaintext, tail);
}

async function generateVnumber(challenge, version) {
  const body = challenge.split("^")[0];
  const keyMaterial = version === "2.0" ? base64ToBytes(body) : legacyHexDecode(body);
  const digest = await sha256(keyMaterial);
  return dynamicTruncate(digest, 2);
}

function legacyHexDecode(value) {
  let normalized = value.trim();
  if (normalized.length % 2) normalized = "0" + normalized;
  return hexToBytes(normalized);
}

function dynamicTruncate(digest, digits) {
  const offset = digest[digest.length - 1] & 0x0f;
  let binary = 0;
  for (let i = 0; i < 4; i += 1) {
    binary = (binary << 8) | (digest[offset + i] & 0xff);
  }
  const value = (binary & 0x7fffffff) % 10 ** digits;
  return String(value).padStart(digits, "0");
}

function vnumberChoices(real) {
  const choices = new Set([real]);
  while (choices.size < 3) {
    const value = Math.floor(Math.random() * 100);
    choices.add(String(value).padStart(2, "0"));
  }
  const arr = Array.from(choices);
  for (let i = arr.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

async function generateEcKeypair() {
  const pair = await subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign"]
  );
  const jwk = await subtle.exportKey("jwk", pair.privateKey);
  const d = base64UrlToBytes(jwk.d);
  const x = base64UrlToBytes(jwk.x);
  const y = base64UrlToBytes(jwk.y);
  const dPad = padBytes(d, 32);
  const xPad = padBytes(x, 32);
  const yPad = padBytes(y, 32);
  const pub = new Uint8Array(64);
  pub.set(xPad, 0);
  pub.set(yPad, 32);
  return { privateHex: bytesToHex(dPad), publicHex: bytesToHex(pub) };
}

async function signP1363Hex(privateHex, data) {
  const dBytes = hexToBytes(privateHex);
  if (dBytes.length !== 32) throw new Error("EC private key must be 32 bytes.");
  const { x, y } = scalarMultBaseP256(BigInt("0x" + privateHex));
  const jwk = {
    kty: "EC",
    crv: "P-256",
    d: bytesToBase64Url(dBytes),
    x: bytesToBase64Url(bigintTo32Bytes(x)),
    y: bytesToBase64Url(bigintTo32Bytes(y)),
    ext: true
  };
  const key = await subtle.importKey(
    "jwk",
    jwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const sig = await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, data);
  return bytesToHex(new Uint8Array(sig));
}

async function rsaOaepSha256Encrypt(data, serverPublicKeyText) {
  const normalized = serverPublicKeyText.trim().replace(/\^/g, ":");
  if (!normalized.includes(":")) {
    throw new Error("Expected RSA public key in exponent^modulus hex format.");
  }
  const [first, second] = normalized.split(":", 2).map((item) => item.trim());
  const a = BigInt("0x" + first);
  const b = BigInt("0x" + second);
  let exponentHex;
  let modulusHex;
  if (bitLen(a) <= 32) {
    exponentHex = first;
    modulusHex = second;
  } else if (bitLen(b) <= 32) {
    exponentHex = second;
    modulusHex = first;
  } else {
    exponentHex = first;
    modulusHex = second;
  }
  const jwk = {
    kty: "RSA",
    n: hexIntToBase64UrlMinimal(modulusHex),
    e: hexIntToBase64UrlMinimal(exponentHex),
    alg: "RSA-OAEP-256",
    ext: true
  };
  const key = await subtle.importKey(
    "jwk",
    jwk,
    { name: "RSA-OAEP", hash: "SHA-256" },
    false,
    ["encrypt"]
  );
  return new Uint8Array(await subtle.encrypt({ name: "RSA-OAEP" }, key, data));
}

async function sha256(data) {
  return new Uint8Array(await subtle.digest("SHA-256", data));
}

const DELTA = new Uint32Array([
  0xc3efe9db, 0x44626b02, 0x79e27c8a, 0x78df30ec,
  0x715ea49e, 0xc785da0a, 0xe04ef22a, 0xe5c40957
]);

function u32(n) {
  return n >>> 0;
}

function rotl(value, bits) {
  bits &= 31;
  return u32((value << bits) | (value >>> (32 - bits)));
}

function rotr(value, bits) {
  bits &= 31;
  return u32((value >>> bits) | (value << (32 - bits)));
}

function wordsLE(data) {
  const out = [];
  for (let i = 0; i < data.length; i += 4) {
    out.push(u32(data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)));
  }
  return out;
}

function wordsToBytesLE(words) {
  const out = new Uint8Array(words.length * 4);
  for (let i = 0; i < words.length; i += 1) {
    const word = u32(words[i]);
    out[i * 4] = word & 0xff;
    out[i * 4 + 1] = (word >>> 8) & 0xff;
    out[i * 4 + 2] = (word >>> 16) & 0xff;
    out[i * 4 + 3] = (word >>> 24) & 0xff;
  }
  return out;
}

class LEA128 {
  constructor(key) {
    if (key.length !== 16) throw new Error("LEA128 requires a 16-byte key.");
    this.roundKeys = LEA128.keySchedule(key);
  }

  static keySchedule(key) {
    const t = wordsLE(key);
    const roundKeys = [];
    for (let i = 0; i < 24; i += 1) {
      const delta = rotl(DELTA[i & 3], i);
      t[0] = rotl(u32(rotl(delta, 0) + t[0]), 1);
      t[1] = rotl(u32(rotl(delta, 1) + t[1]), 3);
      t[2] = rotl(u32(rotl(delta, 2) + t[2]), 6);
      t[3] = rotl(u32(rotl(delta, 3) + t[3]), 11);
      roundKeys.push([t[0], t[1], t[2], t[1], t[3], t[1]]);
    }
    return roundKeys;
  }

  encryptBlock(block) {
    const x = wordsLE(block);
    for (let i = 0; i < 24; i += 4) {
      let rk = this.roundKeys[i];
      x[3] = rotr(u32((x[2] ^ rk[4]) + (rk[5] ^ x[3])), 3);
      x[2] = rotr(u32((x[1] ^ rk[2]) + (rk[3] ^ x[2])), 5);
      x[1] = rotl(u32((x[0] ^ rk[0]) + (rk[1] ^ x[1])), 9);

      rk = this.roundKeys[i + 1];
      x[0] = rotr(u32((x[3] ^ rk[4]) + (x[0] ^ rk[5])), 3);
      x[3] = rotr(u32((x[2] ^ rk[2]) + (x[3] ^ rk[3])), 5);
      x[2] = rotl(u32((x[1] ^ rk[0]) + (rk[1] ^ x[2])), 9);

      rk = this.roundKeys[i + 2];
      x[1] = rotr(u32((x[0] ^ rk[4]) + (x[1] ^ rk[5])), 3);
      x[0] = rotr(u32((x[3] ^ rk[2]) + (x[0] ^ rk[3])), 5);
      x[3] = rotl(u32((x[2] ^ rk[0]) + (rk[1] ^ x[3])), 9);

      rk = this.roundKeys[i + 3];
      x[2] = rotr(u32((x[1] ^ rk[4]) + (x[2] ^ rk[5])), 3);
      x[1] = rotr(u32((x[0] ^ rk[2]) + (x[1] ^ rk[3])), 5);
      x[0] = rotl(u32((x[3] ^ rk[0]) + (rk[1] ^ x[0])), 9);
    }
    return wordsToBytesLE(x);
  }
}

function leaCbcEncrypt(data, key, iv) {
  if (key.length !== 16) throw new Error("LEA-128 key must be 16 bytes.");
  if (iv.length !== 16) throw new Error("LEA-CBC IV must be 16 bytes.");
  const cipher = new LEA128(key);
  let previous = iv;
  const out = new Uint8Array(data.length);
  for (let offset = 0; offset < data.length; offset += 16) {
    const block = new Uint8Array(16);
    for (let i = 0; i < 16; i += 1) {
      block[i] = data[offset + i] ^ previous[i];
    }
    const encrypted = cipher.encryptBlock(block);
    out.set(encrypted, offset);
    previous = encrypted;
  }
  return out;
}

function hexToBytes(hex) {
  let normalized = hex.trim();
  if (normalized.length % 2 === 1) normalized = "0" + normalized;
  const out = new Uint8Array(normalized.length / 2);
  for (let i = 0; i < out.length; i += 1) {
    out[i] = Number.parseInt(normalized.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function bytesToHex(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 1) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out.toUpperCase();
}

function bytesToBase64Url(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

function base64UrlToBytes(value) {
  return new Uint8Array(Buffer.from(value, "base64url"));
}

function base64ToBytes(value) {
  return new Uint8Array(Buffer.from(value, "base64"));
}

function utf8(value) {
  return new TextEncoder().encode(value);
}

function concatBytes(...arrs) {
  const total = arrs.reduce((sum, arr) => sum + arr.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const arr of arrs) {
    out.set(arr, offset);
    offset += arr.length;
  }
  return out;
}

function randomBytes(length) {
  const out = new Uint8Array(length);
  cryptoApi.getRandomValues(out);
  return out;
}

function hexIntToBase64UrlMinimal(hex) {
  let normalized = hex.trim().toLowerCase().replace(/^0x/, "");
  if (normalized.length % 2 === 1) normalized = "0" + normalized;
  let bytes = hexToBytes(normalized);
  let start = 0;
  while (start < bytes.length - 1 && bytes[start] === 0) start += 1;
  bytes = bytes.slice(start);
  return bytesToBase64Url(bytes);
}

function padBytes(bytes, length) {
  if (bytes.length === length) return bytes;
  if (bytes.length > length) return bytes.slice(bytes.length - length);
  const out = new Uint8Array(length);
  out.set(bytes, length - bytes.length);
  return out;
}

function bitLen(value) {
  return value.toString(2).length;
}

const P256_P = BigInt("0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
const P256_A = BigInt("0xffffffff00000001000000000000000000000000fffffffffffffffffffffffc");
const P256_GX = BigInt("0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296");
const P256_GY = BigInt("0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5");
const P256_N = BigInt("0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");

function mod(a, m) {
  const r = a % m;
  return r >= 0n ? r : r + m;
}

function modInverse(a, m) {
  let oldR = mod(a, m);
  let r = m;
  let oldS = 1n;
  let s = 0n;
  while (r !== 0n) {
    const q = oldR / r;
    [oldR, r] = [r, oldR - q * r];
    [oldS, s] = [s, oldS - q * s];
  }
  return mod(oldS, m);
}

function pointAdd(p, q) {
  if (!p) return q;
  if (!q) return p;
  if (p.x === q.x) {
    if (mod(p.y + q.y, P256_P) === 0n) return null;
    return pointDouble(p);
  }
  const slope = mod((q.y - p.y) * modInverse(q.x - p.x, P256_P), P256_P);
  const x = mod(slope * slope - p.x - q.x, P256_P);
  const y = mod(slope * (p.x - x) - p.y, P256_P);
  return { x, y };
}

function pointDouble(p) {
  if (!p) return null;
  const slope = mod((3n * p.x * p.x + P256_A) * modInverse(2n * p.y, P256_P), P256_P);
  const x = mod(slope * slope - 2n * p.x, P256_P);
  const y = mod(slope * (p.x - x) - p.y, P256_P);
  return { x, y };
}

function scalarMult(k, point) {
  let result = null;
  let addend = point;
  while (k > 0n) {
    if (k & 1n) result = pointAdd(result, addend);
    addend = pointDouble(addend);
    k >>= 1n;
  }
  return result;
}

function scalarMultBaseP256(scalar) {
  const k = mod(scalar, P256_N);
  if (k === 0n) throw new Error("EC private scalar must be nonzero.");
  const result = scalarMult(k, { x: P256_GX, y: P256_GY });
  if (!result) throw new Error("EC scalar multiplication produced point at infinity.");
  return result;
}

function bigintTo32Bytes(value) {
  let hex = value.toString(16);
  if (hex.length % 2) hex = "0" + hex;
  return padBytes(hexToBytes(hex), 32);
}

main().catch((error) => {
  process.stderr.write(`${error.message || String(error)}\n`);
  process.exit(1);
});
