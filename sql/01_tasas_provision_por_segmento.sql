/* ============================================================================
   Tasas de provision por segmento (resultado final del informe)
   Dataset "Segmentos" del informe reportes/Tasas_Provision_Deterioro.rdl, extraido
   tal cual para lectura: el .rdl lo embebe porque SSRS no comparte CTE entre datasets.

   Para ejecutarlo fuera de Report Server, declare antes los parametros del informe:
       DECLARE @Rubro    varchar(3) = 'PRU';   -- PRU | PAT | MIL
       DECLARE @AnioBase int        = 2025;    -- ejercicio de corte

   Dependencias en el servidor (no incluidas en este repositorio):
       [pvs].[DeterioroCorteDetalle]  foto congelada del corte
                                      (Rubro, AnioDeuda, AnioPago, ValorDeuda)
       [pvs].[DeterioroIPC]           IPC anual contrastado con el INEC
                                      (Anio, IPC_Factor, IPC_Porcentaje, Verificado, Fuente)
   ============================================================================ */

SET NOCOUNT ON;

/* El IPC se lee de una tabla del servidor. Si no existe, se corta aqui con un
   mensaje legible en vez de fallar mas adelante con un error de objeto. */
IF OBJECT_ID('[PRESUPUESTO_CONTABILIDAD_DM].[pvs].[DeterioroIPC]', 'U') IS NULL
    THROW 50001, 'Falta la tabla [PRESUPUESTO_CONTABILIDAD_DM].[pvs].[DeterioroIPC] con los parametros del IPC. Cree la tabla una sola vez (script no incluido en este repositorio).', 1;

/* El informe lee la FOTO congelada del corte, no las vistas vivas. Si no existe,
   se corta aqui con un mensaje legible en vez de fallar con un error de objeto. */
IF OBJECT_ID('[PRESUPUESTO_CONTABILIDAD_DM].[pvs].[DeterioroCorteDetalle]', 'U') IS NULL
    THROW 50002, 'Falta la foto del corte [PRESUPUESTO_CONTABILIDAD_DM].[pvs].[DeterioroCorteDetalle]. Materialicela con EXEC pvs.sp_CrearCorteDeterioro @FechaCorte = ''<fecha>'' (script no incluido en este repositorio).', 1;

/* ---------------------------------------------------------------------------
   @Desfase — desfase de exigibilidad. La cohorte etiquetada X se vuelve
   exigible en X + @Desfase. El 1.5 por mil grava los activos del ejercicio
   anterior, de modo que su declaracion del ejercicio X recien es exigible en
   X+1.  Predial Urbano y Patente: 0.   1.5 por mil: 1.
   El desfase NO se incorpora a los datos: la matriz conserva el año que
   registra el sistema de origen y cada cobro el año real en que ocurrio.
   --------------------------------------------------------------------------- */
DECLARE @Desfase       int        = CASE WHEN @Rubro = 'MIL' THEN 1 ELSE 0 END;

/* Constantes de la serie. No son parametros del informe: son decisiones
   metodologicas ya tomadas (ver la documentacion de la metodologia). */
DECLARE @AnioInicioSerie    int = 2001;      -- dolarizacion, H-16
DECLARE @AnioInicioCohortes int = 2017;   -- inicio del detalle por año

/* Minimo de cohortes de la PRUEBA DE SENSIBILIDAD. No altera la tasa: la
   metodologia vigente usa todos los puntos de LGD. El informe calcula las dos
   cifras en la misma pasada y las muestra juntas, para que la fragilidad de los
   puntos sostenidos por una sola cohorte quede reportada en toda corrida sin que
   nadie pueda ejecutar por error la version que subestima. Ver H-14. */
DECLARE @MinCohortesSens    int = 3;

DECLARE @AnioFinBloque int        = @AnioInicioCohortes - 1;
DECLARE @EtiqBloque    varchar(9) = CAST(@AnioInicioSerie AS varchar(4)) + '-'
                                  + CAST(@AnioInicioCohortes - 1 AS varchar(4));

IF OBJECT_ID('tempdb..#CRUDO') IS NOT NULL DROP TABLE #CRUDO;
IF OBJECT_ID('tempdb..#CELDA') IS NOT NULL DROP TABLE #CELDA;

/* Cada celda del triangulo de recuperacion: cohorte x año de pago.
      CohorteAnio NULL = bloque consolidado
      AnioPago    NULL = sin pago dentro de la ventana = saldo pendiente
   Va a tabla temporal y no a un CTE porque un CTE se re-evalua en CADA
   referencia, y aqui se referencia media docena de veces: con CTE la consulta
   escanea millones de filas repetidamente y pasa de diez minutos.
   La fuente es la FOTO congelada del corte (una tabla), no las tres vistas vivas:
   se filtra por la columna Rubro y por el rango de año de deuda.

   ---------------------------------------------------------------------------
   DOS ANOMALIAS DE FECHA, DOS TRATAMIENTOS DISTINTOS
   ---------------------------------------------------------------------------
   Un cobro registrado antes del año de exigibilidad de su cohorte queda FUERA
   de la cadena de años de vida: no se resta de ningun saldo vivo, pero su
   importe si esta en la cartera. O sea engorda el denominador del LGD sin que
   nada lo compense, y lo subestima. Hay dos casos y no son el mismo:

   1. PAGO ANTERIOR A LA EMISION  (AñoPago < AñoDeuda)  ->  SE EXCLUYE
      No se puede pagar una deuda que todavia no existe: el registro es
      internamente inconsistente y no se sabe si lo erroneo es el año de deuda o
      el de pago. Inventar una fecha seria peor que descartarlo. Ocurre en Patente y en el 1.5 por mil; ninguno en Predial Urbano.

   2. PAGO ANTICIPADO, DESPUES DE LA EMISION PERO ANTES DE LA EXIGIBILIDAD
      (AñoDeuda <= AñoPago < AñoDeuda + @Desfase)  ->  SE RECLASIFICA al año
      AñoDeuda + @Desfase, el primer año exigible.
      Aqui el registro es coherente: la obligacion existe y se pago antes de
      vencer. El importe pertenece a la cohorte y debe contarse, asi que se lleva
      al año de vida 1 en vez de quedar en un año que no forma parte de su vida.
      Solo puede ocurrir donde el desfase es mayor a cero, es decir en el 1.5 por
      mil: su declaracion del ejercicio X recien es exigible en X+1.

   La regla se escribe con @Desfase y no con un caso especial por rubro: es la
   misma para los tres, y en Predial Urbano y Patente el segundo caso no existe
   porque su desfase es 0.

   #CRUDO conserva la clasificacion para que las validaciones puedan informar
   cuanto se excluyo y cuanto se reclasifico. Sin eso, corregir la anomalia la
   volveria invisible, que es la peor forma de corregir algo. */
SELECT CohorteAnio = CASE WHEN q.[AñoDeuda] <= @AnioFinBloque THEN NULL ELSE q.[AñoDeuda] END,
       AnioPago    = CASE
            WHEN q.[AñoPago] IS NULL                        THEN NULL
            WHEN q.[AñoPago] > @AnioBase + 1                THEN NULL
            WHEN q.[AñoPago] < q.[AñoDeuda] + @Desfase      THEN q.[AñoDeuda] + @Desfase
            ELSE q.[AñoPago] END,
       Clase       = CASE
            WHEN q.[AñoPago] IS NULL                        THEN 'pendiente'
            WHEN q.[AñoPago] < q.[AñoDeuda]                 THEN 'excluido'
            WHEN q.[AñoPago] < q.[AñoDeuda] + @Desfase      THEN 'reclasificado'
            ELSE 'normal' END,
       Valor       = SUM(q.[ValorDeuda])
  INTO #CRUDO
  FROM (
        /* Lee la FOTO congelada, no las vistas vivas: así una misma corrida da
           siempre el mismo resultado. El rubro es una columna de la foto. Se
           alias a los nombres con acento que usa el resto de PASO1, para no tocar
           nada más abajo. El piso (serie) y el tope (año base) siguen aquí: la
           foto es fiel a las vistas y cada informe pone sus propios límites. */
        SELECT [AñoDeuda] = AnioDeuda, [AñoPago] = AnioPago, [ValorDeuda] = ValorDeuda
          FROM [PRESUPUESTO_CONTABILIDAD_DM].[pvs].[DeterioroCorteDetalle]
         WHERE Rubro = @Rubro AND AnioDeuda BETWEEN @AnioInicioSerie AND @AnioBase
       ) q
 GROUP BY CASE WHEN q.[AñoDeuda] <= @AnioFinBloque THEN NULL ELSE q.[AñoDeuda] END,
          CASE
            WHEN q.[AñoPago] IS NULL                        THEN NULL
            WHEN q.[AñoPago] > @AnioBase + 1                THEN NULL
            WHEN q.[AñoPago] < q.[AñoDeuda] + @Desfase      THEN q.[AñoDeuda] + @Desfase
            ELSE q.[AñoPago] END,
          CASE
            WHEN q.[AñoPago] IS NULL                        THEN 'pendiente'
            WHEN q.[AñoPago] < q.[AñoDeuda]                 THEN 'excluido'
            WHEN q.[AñoPago] < q.[AñoDeuda] + @Desfase      THEN 'reclasificado'
            ELSE 'normal' END;

/* El triangulo que consume toda la metodologia: lo mismo que #CRUDO pero sin los
   registros inconsistentes, y con la misma forma de siempre (cohorte, año de
   pago, valor) para que nada aguas abajo tenga que enterarse. */
SELECT CohorteAnio, AnioPago, Valor = SUM(Valor)
  INTO #CELDA
  FROM #CRUDO
 WHERE Clase <> 'excluido'
 GROUP BY CohorteAnio, AnioPago;

;WITH AGG AS (
    SELECT CohorteAnio,
           Cartera = SUM(Valor),
           Saldo   = SUM(CASE WHEN AnioPago IS NULL THEN Valor ELSE 0 END)
      FROM #CELDA GROUP BY CohorteAnio
),
NUM AS (SELECT v FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),
                              (14),(15),(16),(17),(18),(19),(20),(21),(22),(23),(24),
                              (25),(26),(27),(28),(29),(30),(31),(32),(33),(34),(35),
                              (36),(37),(38),(39),(40)) t(v)),
GRID AS (
    /* Un renglon por cohorte individual y año de vida efectivamente alcanzado.
       Años de vida al corte = @AnioBase - (X + @Desfase) + 1. */
    SELECT a.CohorteAnio, a.Cartera, a.Saldo, n.v,
           AnioExigible   = a.CohorteAnio + @Desfase,
           AnioCalendario = a.CohorteAnio + @Desfase + n.v - 1,
           VidaMaxima     = @AnioBase - (a.CohorteAnio + @Desfase) + 1
      FROM AGG a CROSS JOIN NUM n
     WHERE a.CohorteAnio IS NOT NULL
       AND n.v <= @AnioBase - (a.CohorteAnio + @Desfase) + 1
),
GRIDC AS (
    SELECT g.*, CobroDelAnio = ISNULL(c.Valor, 0)
      FROM GRID g
      LEFT JOIN #CELDA c ON c.CohorteAnio = g.CohorteAnio
                        AND c.AnioPago    = g.AnioCalendario
),
SV AS (
    /* Guia 4.2:  Saldo vivo inicio año v = Cartera - SUM(cobros años 1 a v-1).
       Para v=1 ese rango esta VACIO: no se resta nada y el saldo vivo es la
       cartera completa. Es exactamente lo que expresa la ventana
       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING, que da NULL en la
       primera fila de cada cohorte. */
    SELECT *,
           CobrosPrevios = ISNULL(SUM(CobroDelAnio) OVER (
                               PARTITION BY CohorteAnio ORDER BY v
                               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
      FROM GRIDC
),
SVIVO AS (SELECT *, SaldoVivoInicio = Cartera - CobrosPrevios FROM SV),
LGDBASE AS (
    /* LGD_v = SUM(saldo pendiente) / SUM(saldo vivo inicio año v), solo con las
       cohortes de referencia: las que alcanzaron al menos 3 años de vida.
       Una cohorte solo sostiene los años de vida 1..VidaMaxima; usarla mas alla
       produce un LGD de 100% artificial, porque numerador y denominador se
       vuelven el mismo numero (hallazgo H-13). */
    SELECT v,
           Numerador   = SUM(Saldo),
           Denominador = SUM(SaldoVivoInicio),
           LGD         = SUM(Saldo) / NULLIF(SUM(SaldoVivoInicio), 0),
           N           = COUNT(*),
           Cohortes    = STRING_AGG(CAST(CohorteAnio AS varchar(4)), ', ')
                         WITHIN GROUP (ORDER BY CohorteAnio)
      FROM SVIVO WHERE VidaMaxima >= 3 GROUP BY v
),
LGD    AS (SELECT *, LGDPrevio = LAG(LGD) OVER (ORDER BY v) FROM LGDBASE),
/* Año de vida mas maduro con LGD calculable. Lo hereda el bloque consolidado,
   que no tiene recuperacion desagregada (Guia 4.5). */
VTOPE  AS (SELECT VTope    = MAX(v) FROM LGD),
/* Lo mismo, pero exigiendo el minimo de cohortes de la prueba de sensibilidad.
   Es siempre menor o igual que VTope, de modo que el tope de abajo nunca
   extrapola: a lo sumo repite un punto ya calculado. */
VTOPES AS (SELECT VTopeSen = MAX(v) FROM LGD WHERE N >= @MinCohortesSens),
IPCTAB AS (
    /* Los cinco años de referencia que puede necesitar cualquier segmento.
       Solo entran los VERIFICADOS: un año sin contrastar contra el INEC no debe
       influir en una tasa que va a estados financieros. Si falta alguno, el
       promedio del segmento se calcula con menos años y la validacion 6 lo
       reporta en ATENCION. */
    SELECT Anio, IPC = IPC_Factor, Verificado, Fuente, IPC_Porcentaje
      FROM [PRESUPUESTO_CONTABILIDAD_DM].[pvs].[DeterioroIPC]
     WHERE Anio BETWEEN @AnioBase - 5 AND @AnioBase - 1
       AND Verificado = 1
),
IPCTODO AS (   -- igual pero sin filtrar, para mostrar y para validar
    SELECT Anio, IPC = IPC_Factor, Verificado, Fuente, IPC_Porcentaje
      FROM [PRESUPUESTO_CONTABILIDAD_DM].[pvs].[DeterioroIPC]
     WHERE Anio BETWEEN @AnioBase - 5 AND @AnioBase - 1
),
VENTANA AS (
    /* Guia 4.6: cada segmento usa los 3 años inmediatamente anteriores a su
       periodo de referencia (años confirmados en el hallazgo H-09). */
              SELECT Segmento='S1', Desde=@AnioBase-3, Hasta=@AnioBase-1
    UNION ALL SELECT 'S2',                @AnioBase-4,       @AnioBase-2
    UNION ALL SELECT 'S3',                @AnioBase-5,       @AnioBase-3
),
FACTOR AS (
    /* Promedio simple del IPC de la ventana del segmento. ISNULL a 0 para que la
       falta de IPC no anule la tasa en silencio: deja el factor neutro y la
       validacion 6 lo reporta.

       PISO EN CERO POR AÑO — un ejercicio deflacionario aporta 0, no un valor
       negativo (hallazgo H-20, decision metodologica documentada).

       El fundamento es el de la propia Matriz, hoja H3: "el IPC mide la EROSION
       del valor real del dinero en el tiempo (riesgo de valor)". La erosion es
       unidireccional por definicion: un año sin inflacion no erosiona nada, pero
       tampoco mejora la recuperabilidad de una cuenta por cobrar. Y en la practica
       un ejercicio deflacionario en Ecuador (2020, pandemia) coincide con PEOR
       recaudacion, no mejor: dejar que rebaje la provision es contrario en lo
       conceptual y en lo empirico.

       Sin el piso, con el IPC publicado:
         - año base 2021, 2022 y 2023 dan un factor NEGATIVO en algun segmento, y
           la tasa queda POR DEBAJO del LGD;
         - de 2022 a 2025 el factor de S3 queda por debajo del de S1, o sea que el
           ajuste castiga MENOS a la cartera mas antigua.
       Con año base 2026 el piso no cambia nada, porque la ventana 2021-2025 es
       toda positiva: la regla se adopta sin alterar ninguna cifra vigente.

       El piso se aplica AÑO POR AÑO y no al promedio: al promedio, un ejercicio
       deflacionario arrastra hacia abajo la erosion que si aportaron los otros dos
       de su ventana, y el resultado pasa a depender de como queden agrupados los
       años. Por año, cada ejercicio aporta su erosion o aporta cero.

       La tabla conserva el valor PUBLICADO por el INEC, sin tocar: el piso vive
       aqui, en el calculo, donde es una sola decision visible y auditable. El
       informe muestra las dos cifras, promedio publicado y factor aplicado. */
    SELECT w.Segmento, w.Desde, w.Hasta,
           Factor          = ISNULL(a.PromedioPiso, 0),
           FactorPublicado = ISNULL(a.Promedio, 0),
           AniosUsados     = ISNULL(a.Cuantos, 0),
           HayDeflacion    = ISNULL(a.Negativos, 0)
      FROM VENTANA w
      OUTER APPLY (SELECT PromedioPiso = AVG(CASE WHEN i.IPC < 0 THEN 0 ELSE i.IPC END),
                          Promedio     = AVG(i.IPC),
                          Cuantos      = COUNT(*),
                          Negativos    = SUM(CASE WHEN i.IPC < 0 THEN 1 ELSE 0 END)
                     FROM IPCTAB i WHERE i.Anio BETWEEN w.Desde AND w.Hasta) a
),
SEG AS (
    /* Guia 4.4: la segmentacion se define por AÑO DE VIDA, no por año calendario.
          S1 = año de vida 1      S2 = año de vida 2      S3 = 3 en adelante + bloque
       Definida asi, la regla es la misma para los tres rubros: la cohorte del
       "año actual" del 1.5 por mil es la etiquetada con el ejercicio anterior,
       porque es la que se vuelve exigible en el ejercicio en curso.
       El bloque no tiene recuperacion desagregada, asi que recibe el LGD del año
       de vida mas maduro disponible (Guia 4.5). Ese LGD puede estar sostenido por
       UNA sola cohorte, y por eso cada fila trae DOS valores:
          LGD    = el de la metodologia vigente, con todos los puntos
          LGDSen = el de la prueba de sensibilidad, topado en VTopeSen
       El tope es lo que mantiene la comparacion valida: la cohorte cuyo punto no
       cumple el minimo NO sale del calculo, hereda el del tope igual que el
       bloque. Asi las dos columnas se calculan sobre el MISMO saldo y la
       diferencia mide evidencia, no cartera faltante (hallazgo H-14). */
    SELECT Segmento = CASE WHEN s.v = 1 THEN 'S1' WHEN s.v = 2 THEN 'S2' ELSE 'S3' END,
           Cohorte  = CAST(s.CohorteAnio AS varchar(9)),
           Orden    = s.CohorteAnio,
           s.v, l.N, s.Saldo, l.LGD,
           LGDSen   = ls.LGD,
           Clase    = 'cohorte'
      FROM SVIVO s
      JOIN LGD l ON l.v = s.v
     CROSS JOIN VTOPES ts
      JOIN LGD ls ON ls.v = CASE WHEN s.v > ts.VTopeSen THEN ts.VTopeSen ELSE s.v END
     WHERE s.v = s.VidaMaxima      -- cada cohorte entra una vez, en su año de vida actual
    UNION ALL
    SELECT 'S3', @EtiqBloque, 0, t.VTope, l.N, a.Saldo, l.LGD, ls.LGD, 'bloque'
      FROM AGG a
     CROSS JOIN VTOPE t
     CROSS JOIN VTOPES ts
      JOIN LGD l  ON l.v  = t.VTope
      JOIN LGD ls ON ls.v = ts.VTopeSen
     WHERE a.CohorteAnio IS NULL
    UNION ALL
    /* S0 — obligaciones AUN NO EXIGIBLES al corte.
       Solo puede haberlas donde el desfase es mayor a cero, es decir en el 1.5
       por mil: la declaracion del ejercicio X recien es exigible en X+1, asi que
       al corte del propio ejercicio X esa cohorte ya tiene cartera y saldo pero
       todavia no empezo su vida de cobro (su año de vida 1 esta en el futuro).
       No se le aplica deterioro por antiguedad, porque no esta vencida: su tasa
       es 0. Pero ENTRA en el informe a proposito. Antes quedaba fuera de todo
       segmento y su saldo desaparecia en silencio de la segmentacion — con año
       base 2025 era una parte material del saldo del 1.5 por mil. Una exclusion correcta tiene que ser visible, no tacita. */
    SELECT 'S0', CAST(a.CohorteAnio AS varchar(9)), a.CohorteAnio,
           0, 0, a.Saldo, CAST(0 AS decimal(12,8)), CAST(0 AS decimal(12,8)), 'no exigible'
      FROM AGG a
     WHERE a.CohorteAnio IS NOT NULL
       AND a.CohorteAnio + @Desfase > @AnioBase
)

/* COMO SE COMPONE CADA SEGMENTO, como se pondera su LGD y como sale la tasa.
      LGD ponderado del segmento = SUM(Saldo x LGD_v) / SUM(Saldo)    (Guia 4.4)
      Tasa de provision          = LGD ponderado x (1 + factor IPC)   (Guia 4.7)
   Las columnas de agregado se repiten en cada fila del segmento: se calculan por
   funcion de ventana, de modo que el detalle y el resultado salen de una pasada. */
SELECT g.Segmento,
       /* Corta a proposito: la columna del segmento ya dice S0/S1/S2/S3, y en A4
          vertical el ancho no da para repetirlo. La definicion completa de cada
          segmento esta en la prosa del PASO 5. */
       Descripcion = CASE g.Segmento
            WHEN 'S0' THEN 'No exigible al corte'
            WHEN 'S1' THEN 'Año actual (año de vida 1)'
            WHEN 'S2' THEN 'Año anterior (año de vida 2)'
            ELSE           'Año de vida 3 y mas + bloque consolidado' END,
       g.Cohorte, g.Orden, g.v, g.N, g.Saldo, g.LGD,
       Ponderacion   = g.Saldo * g.LGD,
       SaldoSegmento = SUM(g.Saldo) OVER (PARTITION BY g.Segmento),
       LGDPonderado  = SUM(g.Saldo * g.LGD) OVER (PARTITION BY g.Segmento)
                       / NULLIF(SUM(g.Saldo) OVER (PARTITION BY g.Segmento), 0),
       Factor        = ISNULL(f.Factor, 0),
       Tasa          = (SUM(g.Saldo * g.LGD) OVER (PARTITION BY g.Segmento)
                        / NULLIF(SUM(g.Saldo) OVER (PARTITION BY g.Segmento), 0))
                       * (1 + ISNULL(f.Factor, 0)),
       /* PRUEBA DE SENSIBILIDAD — mismas formulas sobre el LGD topado al minimo de
          cohortes. El denominador es el MISMO saldo, asi que la diferencia entre
          Tasa y TasaSen aisla el efecto de exigir mas evidencia. No reemplaza a la
          tasa: se reporta junto a ella (H-14). */
       g.LGDSen,
       LGDPonderadoSen = SUM(g.Saldo * g.LGDSen) OVER (PARTITION BY g.Segmento)
                         / NULLIF(SUM(g.Saldo) OVER (PARTITION BY g.Segmento), 0),
       TasaSen       = (SUM(g.Saldo * g.LGDSen) OVER (PARTITION BY g.Segmento)
                        / NULLIF(SUM(g.Saldo) OVER (PARTITION BY g.Segmento), 0))
                       * (1 + ISNULL(f.Factor, 0)),
       DifSen        = ((SUM(g.Saldo * g.LGDSen) OVER (PARTITION BY g.Segmento)
                         - SUM(g.Saldo * g.LGD) OVER (PARTITION BY g.Segmento))
                        / NULLIF(SUM(g.Saldo) OVER (PARTITION BY g.Segmento), 0))
                       * (1 + ISNULL(f.Factor, 0)),
       Nota = CASE g.Clase
            WHEN 'bloque'      THEN 'Bloque consolidado - proxy: LGD del año de vida mas maduro (Guia 4.5)'
            WHEN 'no exigible' THEN 'Declarado pero aun no exigible: es exigible en '
                                    + CAST(g.Orden + @Desfase AS varchar(4))
                                    + '. No se le aplica deterioro por antiguedad porque no esta vencido.'
            ELSE '' END
  /* LEFT JOIN: S0 no tiene ventana de IPC, y su factor es 0 */
  FROM SEG g LEFT JOIN FACTOR f ON f.Segmento = g.Segmento
 ORDER BY g.Segmento, g.Orden DESC;
