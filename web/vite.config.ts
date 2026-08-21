import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The production build is served by llama.cpp's own static file handler
// (`llama-server --path <root>/web`). Two consequences shape this config:
//
//  1. `base: './'` -- assets must be referenced relatively. The release folder
//     can sit at any path on any drive, and we never know the mount point at
//     build time.
//  2. No code splitting. llama-server serves plain files with no HTTP/2 push
//     and the drive is slow, so one JS file and one CSS file beat a dozen
//     round trips. It also means there are no dynamic-import paths to resolve.
export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    target: 'es2020',
    outDir: 'dist',
    assetsDir: 'assets',
    // Source maps would triple the size on the pendrive for no offline benefit.
    sourcemap: false,
    cssCodeSplit: false,
    chunkSizeWarningLimit: 900,
    rollupOptions: {
      output: {
        manualChunks: undefined,
        entryFileNames: 'assets/app.[hash].js',
        chunkFileNames: 'assets/app.[hash].js',
        assetFileNames: 'assets/[name].[hash][extname]',
      },
    },
  },
  server: {
    // `npm run dev` on a developer machine: proxy the API to a locally running
    // llama-server so the dev UI behaves exactly like the packaged one.
    port: 5173,
    proxy: {
      '/v1': 'http://127.0.0.1:8080',
      '/props': 'http://127.0.0.1:8080',
      '/slots': 'http://127.0.0.1:8080',
    },
  },
})
