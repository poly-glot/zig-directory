import { exportJWK, exportPKCS8, generateKeyPair } from "jose";

const { privateKey, publicKey } = await generateKeyPair("RS256", {
  modulusLength: 2048,
  extractable: true,
});

const privateKeyPem = await exportPKCS8(privateKey);
const publicKeyJwk = await exportJWK(publicKey);
publicKeyJwk.alg = "RS256";
publicKeyJwk.use = "sig";
publicKeyJwk.kid = crypto.randomUUID();

const escapedPem = privateKeyPem.trim().replace(/\n/g, "\\n");

console.log(`MCP_JWT_PRIVATE_KEY_PEM="${escapedPem}"`);
console.log(`MCP_JWT_PUBLIC_KEY_JWK='${JSON.stringify(publicKeyJwk)}'`);
