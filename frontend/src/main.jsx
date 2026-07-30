import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { Toaster } from 'react-hot-toast'
import App from './App'
import { AuthProvider } from './lib/auth'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <App />
      </AuthProvider>
      <Toaster
        position="bottom-right"
        toastOptions={{
          duration: 3500,
          style: {
            fontSize: '13px',
            fontWeight: 600,
            borderRadius: '8px',
            boxShadow: '0 8px 24px rgba(0,0,0,.15)',
          },
          success: { style: { background: '#10b981', color: '#fff' } },
          error:   { style: { background: '#ef4444', color: '#fff' } },
        }}
      />
    </BrowserRouter>
  </React.StrictMode>
)
