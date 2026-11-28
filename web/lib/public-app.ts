import { App } from "fresh";
import { withSecurityHeaders } from "./security-headers.ts";

export class PublicApp<State> extends App<State> {
  override handler(): (
    request: Request,
    info?: Deno.ServeHandlerInfo,
  ) => Promise<Response> {
    const handle = super.handler();

    return async (request, info) => {
      try {
        return await handle(request, info);
      } catch (e) {
        if (!(e instanceof URIError)) throw e;
        return withSecurityHeaders(
          new Response("Malformed percent-encoding in the URL", {
            status: 400,
            headers: { "content-type": "text/plain" },
          }),
        );
      }
    };
  }
}
