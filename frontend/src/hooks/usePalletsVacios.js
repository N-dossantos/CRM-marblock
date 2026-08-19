// src/hooks/usePalletsVacios.js
// Mantiene sincronizada la línea de "Pallet de Madera Vacío" (productos.es_pallet_vacio) con la
// suma de pallets de los demás ítems de la grilla — productos.md §1.2/§3.2.3.
//   * Si no existe la línea y el total de pallets es > 0, la crea.
//   * Si existe y el usuario no la tocó a mano (ItemsTable marca pallets_auto=false al editar su
//     campo Pallets o al elegir el producto a mano), la mantiene sincronizada con el total; si el
//     total cae a 0, la quita.
//   * Si el usuario la editó a mano o la borró, se respeta: sólo vuelve a crearse/recrearse cuando
//     el total de pallets cambia de nuevo (lastAutoTotal deja de coincidir).
//   * Al reabrir un comprobante ya guardado, lo guardado manda: ver "primera pasada" abajo.
import { useEffect, useRef } from 'react'

export function usePalletsVacios(items, setItems, productos, extraLinea = null) {
  const lastAutoTotal  = useRef(null)
  const yaInicializado = useRef(false)

  useEffect(() => {
    // Defensivo: `initial.items` puede llegar null (json_agg ... FILTER devuelve NULL cuando el
    // comprobante no tiene ítems) y `productos` puede no estar cargado todavía.
    const lista    = Array.isArray(items) ? items : []
    const catalogo = Array.isArray(productos) ? productos : []

    const palletProd = catalogo.find(p => p.es_pallet_vacio)
    if (!palletProd) return

    const total = lista.reduce((sum, it) => (
      it.producto_id && !it.es_pallet_vacio && !it.es_transporte
        ? sum + (parseInt(it.pallets, 10) || 0)
        : sum
    ), 0)

    const idx = lista.findIndex(it => it.es_pallet_vacio)

    // ── Primera pasada sobre un comprobante YA GUARDADO ──────────────────────────────
    // `pallets_auto` es sólo de cliente: no se persiste, así que al reabrir un comprobante todos
    // los ítems llegan sin la marca. Sin esta guarda el hook "corregiría" lo que el usuario ya
    // confirmó — recrearía la línea que borró a propósito y pisaría la cantidad que editó a mano
    // (y bastaría con volver a guardar para que ese cambio silencioso quedara persistido).
    // Se toma lo guardado como punto de partida:
    //   * el total guardado pasa a lastAutoTotal, así abrir el comprobante no recrea por sí solo
    //     una línea borrada (sigue reapareciendo si después cambian los pallets, igual que en la
    //     sesión de alta);
    //   * si la línea guardada no coincide con ese total, fue editada a mano → pallets_auto=false.
    if (!yaInicializado.current) {
      yaInicializado.current = true
      if (lista.length > 0) {
        lastAutoTotal.current = total
        if (idx !== -1 && Number(lista[idx].pallets) !== total) {
          setItems(lista.map((it, i) => i !== idx ? it : { ...it, pallets_auto: false }))
        }
        return
      }
    }

    if (idx === -1) {
      if (total > 0 && total !== lastAutoTotal.current) {
        lastAutoTotal.current = total
        setItems([...lista, {
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
          // Campos que dependen del comprobante (p. ej. alicuota_iva_id en facturas multi-alícuota):
          // los pasa el formulario para que la línea automática no quede distinta de las que crea
          // "+ Agregar ítem". No va en las deps: es constante durante la vida del formulario.
          ...(extraLinea || {}),
        }])
      }
      return
    }

    const line = lista[idx]
    // lastAutoTotal tiene que seguir al total en TODA pasada en la que no se crea la línea, no sólo
    // cuando se sincroniza. Si queda viejo (p. ej. la línea es manual y el usuario cambia pallets
    // en otra fila), al borrar la línea el total ya no coincide con el ref y volvería a crearse en
    // el acto: el usuario borra una fila y reaparece sola con otro número.
    if (line.pallets_auto === false) { lastAutoTotal.current = total; return }

    if (total === 0) {
      lastAutoTotal.current = total
      setItems(lista.filter((_, i) => i !== idx))
      return
    }
    if (Number(line.pallets) === total) { lastAutoTotal.current = total; return }

    lastAutoTotal.current = total
    setItems(lista.map((it, i) => i !== idx ? it : { ...it, pallets: total, cantidad: total, pallets_auto: true }))
  }, [items, productos])
}
