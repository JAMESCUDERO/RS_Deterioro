# RS_Deterioro – Tasas de provisión por deterioro de cartera (Vintage + LGD)

**1 reporte paginado (.rdl)** para **Power BI Report Server** que calcula las **tasas de provisión por
deterioro** de una cartera tributaria con **Vintage Analysis** (cohortes), **LGD sobre saldo vivo** y
ajuste por **IPC**, en el marco de **NTCG / NICSP 41**. Todo el cálculo vive en **T-SQL**; el propio
informe documenta la metodología y valida sus resultados.

> Versión saneada de un reporte en producción: el servidor y el nombre de la institución son
> marcadores (`SERVIDOR_DW`, `NOMBRE DE LA INSTITUCIÓN`) y se generalizaron las cifras reales que
> aparecían en los comentarios. **No se incluye ningún dato**: el `.rdl` contiene solo consultas,
> parámetros y diseño.

## Qué resuelve

Dada una cartera por cobrar agrupada por año de emisión (cohorte), responde: *¿qué fracción de lo
emitido termina sin cobrarse, según los años de vida de la deuda?* y lo convierte en una **tasa de
provisión por segmento (S0–S3)** que luego se aplica al saldo vigente para estimar el deterioro.

- **Parámetros:** rubro (`PRU` Impuesto Predial Urbano · `PAT` Patente Municipal · `MIL` 1.5 por mil
  sobre activos totales) y año base. El año base se elige de una lista que arma el propio informe
  (parámetro en cascada), no se teclea.
- **Alcance:** llega hasta la **tasa**. No calcula el deterioro en dólares (eso requiere el saldo
  vigente sobre el cual aplicarla).

## Arquitectura

```text
Vistas de recaudación (3 rubros)
        │  EXEC pvs.sp_CrearCorteDeterioro @FechaCorte    → foto estática del corte
        ▼
[pvs].[DeterioroCorteDetalle]        [pvs].[DeterioroIPC]
 foto congelada de la cartera         IPC anual contrastado con el INEC
        └───────────────┬────────────────┘
                        ▼
   T-SQL:  #CRUDO → #CELDA → CTE (AGG · GRID · SVIVO · LGD · FACTOR · SEG)
                        ▼
   10 datasets  →  informe de 9 secciones (.rdl) en Power BI Report Server
```

## Metodología (resumen)

| Paso | Qué hace |
|---|---|
| 1 · Cohortes | Agrupa cada obligación por su año de deuda; los años previos al primer año desagregado se consolidan en un bloque |
| 2 · Año de vida | La cohorte X es exigible en X + desfase (0 en predial y patente, 1 en el 1.5 por mil); al año base C alcanza C − X − desfase + 1 años de vida |
| 3 · Saldo vivo | Cartera emitida − Σ cobros de los años de vida anteriores |
| 4 · LGD | LGD_v = Σ saldo pendiente / Σ saldo vivo al inicio del año v, solo con cohortes de referencia (≥ 3 años de vida) |
| 5 · Segmentos | S1 = año de vida 1 · S2 = año 2 · S3 = año 3 en adelante + bloque consolidado · S0 = aún no exigible (tasa 0 %) |
| 6 · IPC y tasa | Tasa = LGD ponderado por saldo × (1 + factor IPC); el factor es el promedio simple del IPC de los tres años de referencia de cada segmento |

**Secciones del informe:** 1 Parámetros de la corrida · 2 Cómo se calcula · 3 Matriz de recuperación
y escalera en dólares · 4 Saldo vivo · 5 LGD por año de vida · 6 IPC y factor por segmento ·
7 Composición de segmentos · 8 Resultado (tasas y sensibilidad) · 9 Validaciones de calidad.

## Decisiones técnicas destacadas

- **Reproducibilidad por foto congelada.** El informe lee una foto estática del corte, no las vistas
  vivas: la misma corrida da siempre el mismo resultado, y la fecha y el estado del corte se imprimen
  en el propio informe.
- **Tablas temporales en lugar de CTE** para el triángulo de recuperación: un CTE se reevalúa en cada
  referencia y la consulta superaba los diez minutos.
- **Dos anomalías de fecha, dos tratamientos, ambos trazables.** Pago anterior a la emisión → se
  excluye (registro inconsistente). Pago posterior a la emisión pero anterior a la exigibilidad → se
  reclasifica al primer año exigible. Los controles informan cuánto se excluyó y cuánto se reclasificó.
- **Prueba de sensibilidad en toda corrida.** Junto a la tasa vigente se imprime la que resultaría
  exigiendo un mínimo de 3 cohortes por punto de LGD, calculada sobre el mismo saldo, para que quede a
  la vista cuánto del resultado depende de puntos sostenidos por una o dos cohortes.
- **Factor IPC con piso en cero por año.** Un ejercicio deflacionario aporta 0, no un valor negativo.
  La tabla conserva el valor publicado y el cálculo aplica el piso: una sola decisión, visible y
  auditable.
- **Solo IPC verificado.** Un año sin contrastar contra el INEC queda fuera del promedio y el control 6
  lo reporta.
- **El saldo no desaparece en silencio.** El segmento S0 y el control de completitud (8) existen
  porque una cohorte llegó a quedar fuera de toda segmentación; ahora la suma de los segmentos debe
  reproducir el saldo del rubro.
- **Guardas con mensajes accionables.** Si falta la tabla de IPC o la foto del corte, la consulta se
  detiene con `THROW` y un mensaje legible en lugar de un error de objeto.
- **El cálculo está en SQL, no en el informe.** Se puede ejecutar y verificar en SSMS; el informe solo
  presenta. Los denominadores se pasan a `float` porque la división decimal/decimal fija la escala del
  resultado en 6 y descuadraba los porcentajes.
- **Lista de años barata.** `EXISTS` en lugar de `MAX` sobre la vista completa (medido: de 6,4 s a
  0,6 s en Predial Urbano).

## Controles de calidad

Un `ATENCIÓN` no invalida el resultado, pero obliga a explicarlo. Cada corrida los imprime todos:

| # | Control |
|---|---|
| 1 | Cuadre: cartera − cobros − saldo = 0 en toda cohorte |
| 2 | Pagos anticipados reclasificados al primer año exigible |
| 3 | Monotonicidad del LGD: no decrece al aumentar el año de vida |
| 4 | Cohortes de referencia detrás del año de vida que hereda el bloque consolidado |
| 5 | Cartera de la cohorte más reciente frente a la anterior |
| 6 | IPC disponible y verificado para los 5 años de referencia |
| 7 | Ejercicios deflacionarios en la ventana de IPC |
| 8 | Completitud: todo el saldo del rubro está asignado a un segmento |
| 9 | Obligaciones aún no exigibles al corte (segmento S0) |
| 10 | Sensibilidad: cuánto baja la tasa de S3 exigiendo 3 cohortes por punto de LGD |
| 11 | Registros excluidos por tener el pago anterior a la emisión |

## Alcance y autoría

- **Naturaleza del trabajo:** es un enfoque de **tasa de pérdida por cohortes** sobre una cartera
  tributaria municipal, no un modelo de cartera crediticia PD × LGD × EAD. Comparte con riesgo de
  crédito la lógica de *vintage analysis* y de LGD sobre saldo vivo.
- **Metodología base:** la línea base metodológica la entregó el Ing. Andrés Salas.
- **Mi rol:** ejecución del proyecto sobre esa base: preparación y consolidación de las bases por
  cohorte, cálculo de las tasas y publicación del informe en Report Server.

## Qué no incluye

- Datos, ni los scripts de creación de `pvs.DeterioroCorteDetalle`, `pvs.DeterioroIPC` y
  `pvs.sp_CrearCorteDeterioro` (internos).
- Los documentos metodológicos. Los comentarios del SQL citan secciones de una guía (`Guía §4.x`) y un
  registro de hallazgos de la revisión (`H-NN`); ninguno de los dos se publica.

## Cómo abrirlo

1. Abrir `reportes/Tasas_Provision_Deterioro.rdl` en **Power BI Report Builder** o en Visual Studio
   (Reporting Services).
2. Reemplazar `SERVIDOR_DW` en el origen de datos.
3. Para leer la lógica sin abrir el `.rdl`: [`sql/`](sql/) contiene las dos consultas que cuentan
   la historia completa (tasas por segmento y controles de calidad), extraídas tal cual.

## Stack

SQL Server (T-SQL: tablas temporales, CTE, funciones de ventana, `OUTER APPLY`, `STRING_AGG`,
`THROW`) · Power BI Report Server · Report Builder (RDL) · NTCG / NICSP 41
