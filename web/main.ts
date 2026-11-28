import { staticFiles } from "fresh";
import { type State } from "./utils.ts";
import { bodyLimit } from "./lib/body-limit.ts";
import { PublicApp } from "./lib/public-app.ts";
import { securityHeaders } from "./lib/security-headers.ts";

export const app = new PublicApp<State>();

app.use(securityHeaders);
app.use(bodyLimit);
app.use(staticFiles());
app.fsRoutes();
