import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
  server: {
    port: 8081,
    host: true,
    proxy: {
      '/api': {
        target: process.env.VITE_API_URL ?? 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
  build: {
    // Lands at packages/pi-portal/web-dist — the pi-portal server (see
    // server/src/index.ts) serves this directory directly, so the whole
    // portal is one same-origin process once built and deployed.
    outDir: '../web-dist',
    emptyOutDir: true,
  },
})
