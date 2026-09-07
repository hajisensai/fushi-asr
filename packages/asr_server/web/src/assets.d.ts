// esbuild inlines these as data URIs (build.mjs); Vite serves them from the dev server.
declare module '*.png' {
  const src: string;
  export default src;
}
