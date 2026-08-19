// src/hooks/usePalletsVacios.js
// Mantiene sincronizada la línea de "Pallet de Madera Vacío" (productos.es_pallet_vacio) con la
// suma de pallets de los demás ítems de la grilla — productos.md §1.2/§3.2.3.
//   * Si no existe la línea y el total de pallets es > 0, la crea.
//   * Si existe y el usuario no la tocó a mano (ItemsTable marca pallets_auto=false al editar su
//     campo Pallets), la mantiene sincronizada con el total; si el total cae a 0, la quita.
//   * Si el usuario la editó a mano o la borró, se respeta: sólo vuelve a crearse/recrearse cuando
//     el total de pallets cambia de nuevo (lastAutoTotal deja de coincidir).
import { useEffect, useRef } from 'react'

export function usePalletsVacios(items, setItems, productos) {
  const lastAutoTotal = useRef(null)

  useEffect(() => {
    const palletProd = productos.find(p => p.es_pallet_vacio)
    if (!palletProd) return

    const total = items.reduce((sum, it) => (
      it.producto_id && !it.es_pallet_vacio && !it.es_transporte
        ? sum + (parseInt(it.pallets, 10) || 0)
        : sum
    ), 0)

    const idx = items.findIndex(it => it.es_pallet_vacio)

    if (idx === -1) {
      if (total > 0 && total !== lastAutoTotal.current) {
        lastAutoTotal.current = total
        setItems([...items, {
          producto_id:         palletProd.id,
          descripcion:         palletProd.descripcion,
          precio_unitario:     palletProd.precio_sin_iva,
          descuento_item:      0,
          unidades_por_pallet: 1,
          es_pallet_vacio:     true,
          es_transporte:       false,
          pallets:             total,
          cantidad:            total,
          pallets_auto:        true,
        }])
      }
      return
    }

    const line = items[idx]
    if (line.pallets_auto === false) return

    if (total === 0) {
      lastAutoTotal.current = total
      setItems(items.filter((_, i) => i !== idx))
      return
    }
    if (Number(line.pallets) === total) return

    lastAutoTotal.current = total
    setItems(items.map((it, i) => i !== idx ? it : { ...it, pallets: total, cantidad: total, pallets_auto: true }))
  }, [items, productos])
}
