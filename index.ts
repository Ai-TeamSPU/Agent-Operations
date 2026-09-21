import { createHandler } from './core.mjs';
Deno.serve(createHandler({env: (name: string) => Deno.env.get(name)}));

