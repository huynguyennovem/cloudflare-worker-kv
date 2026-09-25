/**
 * Cloudflare Worker that serves remote config stored in Workers KV.
 * Only the default handler may be exported from this entry module.
 */
import { handleRequest, type Env } from "./config";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },
} satisfies ExportedHandler<Env>;
