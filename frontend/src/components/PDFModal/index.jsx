// src/components/PDFModal/index.jsx
// Modal universal para ver / descargar / imprimir cualquier comprobante PDF
import { useState, useEffect, useRef } from 'react'
import { supabase } from '../../lib/supabase'
import { useEscape } from '../../hooks/useEscape'

// Los PDF los genera la Edge Function `pdf` de Supabase (Fase 6). Las vistas siguen pasando la
// misma `url` estilo Express ("/api/pdf/factura/12"): acá le quitamos el prefijo y la mapeamos a
// {SUPABASE_URL}/functions/v1/pdf/<path>, con el JWT de la sesión (RLS: sólo staff autenticado).
const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/pdf`

// En iPhone/iPad un PDF dentro de un iframe se dibuja como una imagen de la primera página y nada
// más (Android directamente no lo muestra). En celulares y tablets no se usa el iframe: se abre en
// una pestaña nueva, con el visor del sistema (todas las páginas, compartir, imprimir), o se descarga.
const SIN_VISOR_EMBEBIDO = '(max-width: 760px), (pointer: coarse)'

/**
 * Props:
 *   url        {string}  – ruta estilo Express, ej. "/api/pdf/factura/12" (o con querystring)
 *   titulo     {string}  – título del modal
 *   talonario  {bool}    – el PDF es una sobreimpresión sobre formulario preimpreso: muestra
 *                          el aviso de escala, porque "Ajustar a la página" desalinea todo
 *   onClose    {fn}      – cierra el modal
 */
export default function PDFModal({ url, titulo, talonario = false, onClose }) {
  const [estado, setEstado]     = useState('cargando') // cargando | ok | error
  const [blobUrl, setBlobUrl]   = useState(null)
  const [errorMsg, setErrorMsg] = useState('')
  const [movil]                 = useState(() => window.matchMedia(SIN_VISOR_EMBEBIDO).matches)
  const iframeRef               = useRef(null)
  useEscape(onClose)

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

  // Se abre en el clic: fuera de un gesto del usuario el navegador lo bloquea como popup.
  const abrir = () => {
    if (blobUrl) window.open(blobUrl, '_blank')
  }

  const imprimir = () => {
    if (!iframeRef.current) return
    iframeRef.current.contentWindow?.focus()
    iframeRef.current.contentWindow?.print()
  }

  return (
    <div
      className="pdf-modal"
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
        background: 'var(--surface)',
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
            <span style={{ fontSize: 'calc(18px * var(--font-scale))' }}>📄</span>
            <span style={{ color: '#fff', fontWeight: 700, fontSize: 'calc(14px * var(--font-scale))' }}>{titulo}</span>
          </div>

          {/* Botones de acción */}
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            {estado === 'ok' && !movil && (
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
                    fontSize: 'calc(13px * var(--font-scale))',
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
                    fontSize: 'calc(13px * var(--font-scale))',
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
                fontSize: 'calc(24px * var(--font-scale))',
                lineHeight: 1,
                cursor: 'pointer',
                padding: '2px 6px',
                borderRadius: 6,
              }}
            >×</button>
          </div>
        </div>

        {/* Aviso de escala: en sobreimpresión, "Ajustar a la página" encoge un 3-6% y
            corre todos los campos varios milímetros — es el error más probable. */}
        {talonario && estado === 'ok' && (
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '9px 20px',
            background: 'var(--amber-100)',
            borderBottom: '1px solid var(--amber-100)',
            color: 'var(--amber-700)',
            fontSize: 'calc(12.5px * var(--font-scale))',
            flexShrink: 0,
          }}>
            <span>⚠️</span>
            <span>
              Al imprimir, poné <strong>Escala 100 % (Tamaño real)</strong> y <strong>Márgenes: ninguno</strong>.
              Si queda en «Ajustar a la página» los datos salen corridos del formulario.
              Son <strong>2 hojas</strong>: original y duplicado.
            </span>
          </div>
        )}

        {/* Contenido */}
        <div style={{ flex: 1, overflow: 'hidden', background: '#525659', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {estado === 'cargando' && (
            <div style={{ color: '#fff', fontSize: 'calc(14px * var(--font-scale))', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
              <div style={{ width: 36, height: 36, border: '3px solid rgba(255,255,255,.2)', borderTopColor: '#fff', borderRadius: '50%', animation: 'spin 0.8s linear infinite' }} />
              Generando PDF…
            </div>
          )}
          {estado === 'error' && (
            <div style={{ color: '#fff', textAlign: 'center', padding: 40 }}>
              <div style={{ fontSize: 'calc(40px * var(--font-scale))', marginBottom: 12 }}>⚠️</div>
              <div style={{ fontWeight: 700, fontSize: 'calc(15px * var(--font-scale))', marginBottom: 6 }}>No se pudo generar el PDF</div>
              <div style={{ opacity: .7, fontSize: 'calc(13px * var(--font-scale))' }}>{errorMsg}</div>
              <button
                onClick={onClose}
                style={{ marginTop: 20, padding: '8px 20px', background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)', borderRadius: 8, color: '#fff', cursor: 'pointer', fontFamily: 'inherit', fontSize: 'calc(13px * var(--font-scale))' }}
              >
                Cerrar
              </button>
            </div>
          )}
          {estado === 'ok' && blobUrl && (movil ? (
            <div style={{ color: '#fff', textAlign: 'center', padding: 24, width: '100%', maxWidth: 340, display: 'flex', flexDirection: 'column', alignItems: 'stretch', gap: 12 }}>
              <div style={{ fontSize: 'calc(40px * var(--font-scale))' }}>📄</div>
              <div style={{ fontWeight: 700, fontSize: 'calc(15px * var(--font-scale))', marginBottom: 8 }}>El PDF está listo</div>
              <button
                onClick={abrir}
                style={{ minHeight: 48, padding: '12px 20px', background: '#1d4ed8', border: 'none', borderRadius: 8, color: '#fff', fontWeight: 600, fontSize: 'calc(15px * var(--font-scale))', cursor: 'pointer', fontFamily: 'inherit' }}
              >
                📄 Abrir PDF
              </button>
              <button
                onClick={descargar}
                style={{ minHeight: 48, padding: '12px 20px', background: 'rgba(255,255,255,.12)', border: '1px solid rgba(255,255,255,.25)', borderRadius: 8, color: '#fff', fontWeight: 600, fontSize: 'calc(15px * var(--font-scale))', cursor: 'pointer', fontFamily: 'inherit' }}
              >
                ⬇ Descargar
              </button>
            </div>
          ) : (
            <iframe
              ref={iframeRef}
              src={blobUrl}
              title={titulo}
              style={{ width: '100%', height: '100%', border: 'none' }}
            />
          ))}
        </div>
      </div>

      <style>{`
        @keyframes spin { to { transform: rotate(360deg); } }
      `}</style>
    </div>
  )
}
