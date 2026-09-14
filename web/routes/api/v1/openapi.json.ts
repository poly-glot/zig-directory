import { define } from "../../../utils.ts";
import { openapi } from "./_lib/openapi.ts";

export const handler = define.handlers({
  GET() {
    return Response.json(openapi);
  },
});
