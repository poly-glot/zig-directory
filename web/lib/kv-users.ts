/// <reference lib="deno.unstable" />

export type UserRole = "user" | "editor" | "admin";

export interface User {
  id: string;
  email: string;
  username: string;
  passwordHash: string;
  role: UserRole;
  displayName: string;
  bio: string;
  avatarUrl: string;
  createdAt: string;
  updatedAt: string;
}

let _kv: Deno.Kv | null = null;

export async function getKv(): Promise<Deno.Kv> {
  if (!_kv) {
    const path = Deno.env.get("KV_PATH") || "./data/users.db";
    _kv = await Deno.openKv(path);
  }
  return _kv;
}

function hexEncode(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function hexDecode(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const encoder = new TextEncoder();
  const keyMaterial = await crypto.subtle.importKey(
    "raw",
    encoder.encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    {
      name: "PBKDF2",
      salt: salt.buffer as ArrayBuffer,
      iterations: 100000,
      hash: "SHA-256",
    },
    keyMaterial,
    256,
  );
  return `${hexEncode(salt.buffer as ArrayBuffer)}:${hexEncode(bits)}`;
}

async function verifyPassword(
  password: string,
  storedHash: string,
): Promise<boolean> {
  const [saltHex, hashHex] = storedHash.split(":");
  const salt = hexDecode(saltHex);
  const encoder = new TextEncoder();
  const keyMaterial = await crypto.subtle.importKey(
    "raw",
    encoder.encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    {
      name: "PBKDF2",
      salt: salt.buffer as ArrayBuffer,
      iterations: 100000,
      hash: "SHA-256",
    },
    keyMaterial,
    256,
  );
  return hexEncode(bits) === hashHex;
}

export async function createUser(
  email: string,
  username: string,
  password: string,
  role: UserRole = "user",
): Promise<User> {
  const kv = await getKv();

  // Check if email already exists
  const existingByEmail = await kv.get(["users_by_email", email.toLowerCase()]);
  if (existingByEmail.value) {
    throw new Error("A user with this email already exists");
  }

  // Check if username already exists
  const existingByUsername = await kv.get([
    "users_by_username",
    username.toLowerCase(),
  ]);
  if (existingByUsername.value) {
    throw new Error("A user with this username already exists");
  }

  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const passwordHash = await hashPassword(password);

  const user: User = {
    id,
    email: email.toLowerCase(),
    username: username.toLowerCase(),
    passwordHash,
    role,
    displayName: username,
    bio: "",
    avatarUrl: "",
    createdAt: now,
    updatedAt: now,
  };

  const result = await kv
    .atomic()
    .check(existingByEmail)
    .check(existingByUsername)
    .set(["users", id], user)
    .set(["users_by_email", email.toLowerCase()], id)
    .set(["users_by_username", username.toLowerCase()], id)
    .commit();

  if (!result.ok) {
    throw new Error(
      "Failed to create user — email or username may already be taken",
    );
  }

  return user;
}

export async function authenticateUser(
  email: string,
  password: string,
): Promise<User | null> {
  const user = await getUserByEmail(email);
  if (!user) return null;

  const valid = await verifyPassword(password, user.passwordHash);
  if (!valid) return null;

  return user;
}

export async function getUserById(id: string): Promise<User | null> {
  const kv = await getKv();
  const entry = await kv.get<User>(["users", id]);
  return entry.value ?? null;
}

export async function getUserByEmail(email: string): Promise<User | null> {
  const kv = await getKv();
  const idEntry = await kv.get<string>(["users_by_email", email.toLowerCase()]);
  if (!idEntry.value) return null;
  return getUserById(idEntry.value);
}

export async function updateUser(
  id: string,
  updates: Partial<Pick<User, "displayName" | "bio" | "avatarUrl">>,
): Promise<User | null> {
  const kv = await getKv();
  const entry = await kv.get<User>(["users", id]);
  if (!entry.value) return null;

  const user: User = {
    ...entry.value,
    ...updates,
    updatedAt: new Date().toISOString(),
  };

  const result = await kv
    .atomic()
    .check(entry)
    .set(["users", id], user)
    .commit();

  if (!result.ok) {
    throw new Error("Failed to update user — concurrent modification");
  }

  return user;
}

export async function listUsers(): Promise<User[]> {
  const kv = await getKv();
  const users: User[] = [];
  const iter = kv.list<User>({ prefix: ["users"] });
  for await (const entry of iter) {
    // Skip index entries (users_by_email, users_by_username share prefix "users")
    if (entry.key.length === 2 && entry.key[0] === "users") {
      users.push(entry.value);
    }
  }
  return users;
}

export async function deleteUser(id: string): Promise<boolean> {
  const kv = await getKv();
  const entry = await kv.get<User>(["users", id]);
  if (!entry.value) return false;

  const user = entry.value;
  await kv
    .atomic()
    .check(entry)
    .delete(["users", id])
    .delete(["users_by_email", user.email])
    .delete(["users_by_username", user.username])
    .commit();

  return true;
}

export async function getUserCount(): Promise<number> {
  const kv = await getKv();
  let count = 0;
  const iter = kv.list({ prefix: ["users"] });
  for await (const entry of iter) {
    if (entry.key.length === 2 && entry.key[0] === "users") {
      count++;
    }
  }
  return count;
}
