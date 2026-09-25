declare namespace Cloudflare {
  interface GlobalProps {
    mainModule: typeof import("../src/index");
  }
  interface Env {
    CONFIG_KV: KVNamespace;
    CLIENT_KEY?: string;
  }
}
