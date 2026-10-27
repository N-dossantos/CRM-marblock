import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { Toaster } from 'react-hot-toast'
import App from './App'
import { AuthProvider } from './lib/auth'
import { ThemeProvider } from './lib/theme'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <ThemeProvider>
        <AuthProvider>
          <App />
        </AuthProvider>
        <Toaster
          position="bottom-right"
          toastOptions={{
            duration: 3500,
            style: {
              fontSize: 'calc(13px * var(--font-scale))',
              fontWeight: 600,
              borderRadius: '8px',
              boxShadow: '0 8px 24px rgba(0,0,0,.15)',
              background: 'var(--surface)',
              color: 'var(--gray-800)',
              border: '1px solid var(--gray-200)',
            },
            success: { style: { background: 'var(--green-50)', color: 'var(--green-700)', borderColor: 'var(--green-100)' } },
            error:   { style: { background: 'var(--red-50)', color: 'var(--red-600)', borderColor: 'var(--red-100)' } },
          }}
        />
      </ThemeProvider>
    </BrowserRouter>
  </React.StrictMode>
)
