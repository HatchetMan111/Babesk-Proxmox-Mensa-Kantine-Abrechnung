import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Im Dev-Modus /api auf die FastAPI (localhost:8000) proxen.
// Im Build wird alles statisch nach dist/ geschrieben und von FastAPI ausgeliefert.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { '/api': 'http://127.0.0.1:8000' },
  },
  build: { outDir: 'dist', emptyOutDir: true },
})