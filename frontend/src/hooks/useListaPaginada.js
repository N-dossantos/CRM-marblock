// src/hooks/useListaPaginada.js
// Listas de comprobantes paginadas en el servidor (M11): con la historia de Tango cargada, traer
// todas las facturas eran ~4.600 filas y ~9 MB de JSON. La RPC recibe limit/offset y cada fila trae
// `total_filas` (el total que cumple el filtro) — y en recibos / órdenes de pago `total_importe`, la
// suma de `total` del filtro completo —, así que alcanza con una sola llamada por página.
//
//   const { rows, total, totalImporte, loading, pagina, setPagina, recargar } =
//     useListaPaginada(FacturasAPI.list, { q: search, estado: filtroEst })
//
// * Si cambian los filtros se vuelve a la página 1 en el mismo render (no en un efecto aparte, que
//   haría una consulta de más con la página vieja).
// * Si llega tarde la respuesta de una consulta anterior (tipeo rápido en el buscador), se descarta.
import { useCallback, useEffect, useRef, useState } from 'react'

export const POR_PAGINA = 50

export function useListaPaginada(listar, filtros) {
  const [rows, setRows]       = useState([])
  const [total, setTotal]     = useState(0)
  const [totalImporte, setTotalImporte] = useState(0)
  const [loading, setLoading] = useState(true)
  const [pagina, setPagina]   = useState(0)
  const pedido = useRef(0)

  const clave = JSON.stringify(filtros)
  const [claveVista, setClaveVista] = useState(clave)
  if (clave !== claveVista) {
    setClaveVista(clave)
    setPagina(0)
  }

  const recargar = useCallback(() => {
    const id = ++pedido.current
    setLoading(true)
    return listar({ ...JSON.parse(clave), limit: POR_PAGINA, offset: pagina * POR_PAGINA })
      .then(r => {
        if (id !== pedido.current) return
        // Se borró/anuló lo último de la última página: volver a la anterior en vez de mostrar vacío.
        if (!r.length && pagina > 0) { setPagina(p => p - 1); return }
        setRows(r)
        setTotal(r[0]?.total_filas ?? 0)
        setTotalImporte(+(r[0]?.total_importe ?? 0))
      })
      .finally(() => { if (id === pedido.current) setLoading(false) })
  }, [listar, clave, pagina])

  useEffect(() => { recargar() }, [recargar])

  return { rows, total, totalImporte, loading, pagina, setPagina, recargar }
}
