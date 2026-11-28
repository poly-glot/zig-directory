export async function call(
  route: { GET?: unknown },
  path: string,
  params: Record<string, string> = {},
): Promise<{ status: number; body: { error?: string } }> {
  const url = new URL(`http://dmoz.test${path}`);
  const get = route.GET as (ctx: unknown) => Promise<Response>;
  const response = await get({ url, req: new Request(url), params });
  return { status: response.status, body: await response.json() };
}
