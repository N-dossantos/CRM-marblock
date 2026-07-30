// src/components/PDFModal/index.jsx
// Modal universal para ver / descargar / imprimir cualquier comprobante PDF
import { useState, useEffect, useRef } from 'react'
import { supabase } from '../../lib/supabase'

// Los PDF los genera la Edge Function `pdf` de Supabase (Fase 6). Las vistas siguen pasando la
// misma `url` estilo Express ("/api/pdf/factura/12"): acá le quitamos el prefijo y la mapeamos a
// {SUPABASE_URL}/functions/v1/pdf/<path>, con el JWT de la sesión (RLS: sólo staff autenticado).
const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/pdf`

/**
 * Props:
 *   url      {string}  – ruta estilo Express, ej. "/api/pdf/factura/12" (o con querystring)
 *   titulo   {string}  – título del modal
 *   onClose  {fn}      – cierra el modal
 */
export default function PDFModal({ url, titulo, onClose }) {
  const [estado, setEstado]     = useState('cargando') // cargando | ok | error
  const [blobUrl, setBlobUrl]   = useState(null)
  const [errorMsg, setErrorMsg] = useState('')
  const iframeRef               = useRef(null)

  useEffect(() => {
    let objectUrl = null
    let cancelado = false

    const path    = url.replace(/^\/api\/pdf\//, '')
    const destino = `${FUNCTIONS_BASE}/${path}`

    ;(async () => {
      try {
        const { data: { session } } = await supabase.auth.getSession()
        if (!session) throw new Error('Sesión expirada — iniciá sesión nuevamente.')

        const res = await fetch(destino, {
          headers: {
            Authorization: `Bearer ${session.access_token}`,
            apikey: import.meta.env.VITE_SUPABASE_ANON_KEY,
          },
        })
        if (!res.ok) {
          const d = await res.json().catch(() => ({}))
          throw new Error(d.error || 'Error al generar PDF')
        }
        const blob = await res.blob()
        if (cancelado) return
        objectUrl = URL.createObjectURL(blob)
        setBlobUrl(objectUrl)
        setEstado('ok')
      } catch (err) {
        if (cancelado) return
        setErrorMsg(err.message || 'No se pudo generar el PDF')
        setEstado('error')
      }
    })()

    return () => { cancelado = true; if (objectUrl) URL.revokeObjectURL(objectUrl) }
  }, [url])

  const descargar = () => {
    if (!blobUrl) return
    const a    = document.createElement('a')
    a.href     = blobUrl
    a.download = `${titulo.replace(/\s+/g, '_')}.pdf`
    a.click()
  }

  const imprimir = () => {
    if (!iframeRef.current) return
    iframeRef.current.contentWindow?.focus()
    iframeRef.current.contentWindow?.print()
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0,
        background: 'rgba(0,0,0,.65)',
        zIndex: 2000,
        display: 'flex', flexDirection: 'column',
        alignItems: 'center', justifyContent: 'center',
        padding: 16,
      }}
      onClick={e => e.target === e.currentTarget && onClose()}
    >
      <div style={{
        background: '#fff',
        borderRadius: 12,
        width: '100%',
        maxWidth: 860,
        height: '92vh',
        display: 'flex',
        flexDirection: 'column',
        boxShadow: '0 24px 60px rgba(0,0,0,.4)',
        overflow: 'hidden',
      }}>
        {/* Header del modal */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '14px 20px',
          background: '#0f2645',
          flexShrink: 0,
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ fontSize: 18 }}>📄</span>
            <span style={{ color: '#fff', fontWeight: 700, fontSize: 14 }}>{titulo}</span>
          </div>

          {/* Botones de acción */}
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            {estado === 'ok' && (
              <>
                <button
                  onClick={imprimir}
                  title="Imprimir"
                  style={{
                    display: 'flex', alignItems: 'center', gap: 6,
                    padding: '7px 14px',
                    background: 'rgba(255,255,255,.12)',
                    border: '1px solid rgba(255,255,255,.2)',
                    borderRadius: 7,
                    color: '#fff',
                    fontSize: 13,
                    fontWeight: 600,
                    cursor: 'pointer',
                    fontFamily: 'inherit',
                    transition: 'background .15s',
                  }}
                  onMouseOver={e => e.currentTarget.style.background = 'rgba(255,255,255,.22)'}
                  onMouseOut={e => e.currentTarget.style.background = 'rgba(255,255,255,.12)'}
                >
                  🖨 Imprimir
                </button>
                <button
                  onClick={descargar}
                  title="Descargar PDF"
                  style={{
                    display: 'flex', alignItems: 'center', gap: 6,
                    padding: '7px 14px',
                    background: '#1d4ed8',
                    border: 'none',
                    borderRadius: 7,
                    color: '#fff',
                    fontSize: 13,
                    fontWeight: 600,
                    cursor: 'pointer',
                    fontFamily: 'inherit',
                    transition: 'opacity .15s',
                  }}
                  onMouseOver={e => e.currentTarget.style.opacity = '.85'}
                  onMouseOut={e => e.currentTarget.style.opacity = '1'}
                >
                  ⬇ Descargar
                </button>
              </>
            )}
            <button
              onClick={onClose}
              style={{
                background: 'none',
                border: 'none',
                color: 'rgba(255,255,255,.7)',
                fontSize: 24,
                lineHeight: 1,
                cursor: 'pointer',
                padding: '2px 6px',
                borderRadius: 6,
              }}
            >×</button>
          </div>
        </div>

        {/* Contenido */}
        <div style={{ flex: 1, overflow: 'hidden', background: '#525659', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {estado === 'cargando' && (
            <div style={{ color: '#fff', fontSize: 14, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
              <div style={{ width: 36, height: 36, border: '3px solid rgba(255,255,255,.2)', borderTopColor: '#fff', borderRadius: '50%', animation: 'spin 0.8s linear infinite' }} />
              Generando PDF…
            </div>
          )}
          {estado === 'error' && (
            <div style={{ color: '#fff', textAlign: 'center', padding: 40 }}>
              <div style={{ fontSize: 40, marginBottom: 12 }}>⚠️</div>
              <div style={{ fontWeight: 700, fontSize: 15, marginBottom: 6 }}>No se pudo generar el PDF</div>
              <div style={{ opacity: .7, fontSize: 13 }}>{errorMsg}</div>
              <button
                onClick={onClose}
                style={{ marginTop: 20, padding: '8px 20px', background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)', borderRadius: 8, color: '#fff', cursor: 'pointer', fontFamily: 'inherit', fontSize: 13 }}
              >
                Cerrar
              </button>
            </div>
          )}
          {estado === 'ok' && blobUrl && (
            <iframe
              ref={iframeRef}
              src={blobUrl}
              title={titulo}
              style={{ width: '100%', height: '100%', border: 'none' }}
            />
          )}
        </div>
      </div>

      <style>{`
        @keyframes spin { to { transform: rotate(360deg); } }
      `}</style>
    </div>
  )
}
