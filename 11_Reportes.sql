USE Com5600G13;
GO

CREATE OR ALTER PROCEDURE reportes.Sp_FlujoCajaSemanal
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL,
    @IdConsorcio INT  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @FechaFin    = CONVERT(date, ISNULL(@FechaFin,    GETDATE()));
    SET @FechaInicio = CONVERT(date, ISNULL(@FechaInicio, DATEADD(MONTH, -3, @FechaFin)));

    ;WITH G AS (
        SELECT
            g.nroExpensa,
            g.idConsorcio,
            SUM(CASE WHEN g.tipo='Ordinario'      THEN g.importe ELSE 0 END) AS ord_g,
            SUM(CASE WHEN g.tipo='Extraordinario' THEN g.importe ELSE 0 END) AS ext_g
        FROM app.Tbl_Gasto g
        GROUP BY g.nroExpensa, g.idConsorcio
    ),
    EC AS (
        SELECT
            ec.nroExpensa,
            ec.idConsorcio,
            SUM(ISNULL(ec.expensasOrdinarias,0))      AS ord_ec,
            SUM(ISNULL(ec.expensasExtraordinarias,0)) AS ext_ec
        FROM app.Tbl_EstadoCuenta ec
        GROUP BY ec.nroExpensa, ec.idConsorcio
    ),
    Proporciones AS (
        SELECT
            COALESCE(G.nroExpensa, EC.nroExpensa)   AS nroExpensa,
            COALESCE(G.idConsorcio, EC.idConsorcio) AS idConsorcio,
            -- preferir Gasto si trae importes; si no, usar EstadoCuenta
            COALESCE(NULLIF(G.ord_g,0), EC.ord_ec, 0) AS totalOrdinario,
            COALESCE(NULLIF(G.ext_g,0), EC.ext_ec, 0) AS totalExtraordinario
        FROM G
        FULL JOIN EC
          ON EC.nroExpensa  = G.nroExpensa
         AND EC.idConsorcio = G.idConsorcio
    ),
    PagosPorSemana AS (
        SELECT
            DATEADD(WEEK, DATEDIFF(WEEK, 0, p.fecha), 0) AS inicioSemana,
            SUM( p.monto *
                 CASE
                   WHEN ISNULL(pr.totalOrdinario,0)+ISNULL(pr.totalExtraordinario,0) > 0
                        THEN CAST(pr.totalOrdinario AS DECIMAL(18,6))
                             / (pr.totalOrdinario+pr.totalExtraordinario)
                   ELSE 0.5
                 END
               ) AS recaudacionOrdinaria,
            SUM( p.monto *
                 CASE
                   WHEN ISNULL(pr.totalOrdinario,0)+ISNULL(pr.totalExtraordinario,0) > 0
                        THEN CAST(pr.totalExtraordinario AS DECIMAL(18,6))
                             / (pr.totalOrdinario+pr.totalExtraordinario)
                   ELSE 0.5
                 END
               ) AS recaudacionExtraordinaria,
            SUM(p.monto) AS recaudacionTotal
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_Expensa e 
                ON e.nroExpensa  = p.nroExpensa
               AND e.idConsorcio = p.idConsorcio
        LEFT JOIN Proporciones pr
               ON pr.nroExpensa  = e.nroExpensa
              AND pr.idConsorcio = e.idConsorcio
        WHERE p.fecha >= @FechaInicio
          AND p.fecha <  DATEADD(DAY, 1, @FechaFin)
          AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
        GROUP BY DATEADD(WEEK, DATEDIFF(WEEK, 0, p.fecha), 0)
    )
    SELECT
        CAST(inicioSemana AS date) AS inicioSemana,
        CAST(recaudacionOrdinaria      AS DECIMAL(18,2)) AS recaudacionOrdinaria,
        CAST(recaudacionExtraordinaria AS DECIMAL(18,2)) AS recaudacionExtraordinaria,
        CAST(recaudacionTotal          AS DECIMAL(18,2)) AS recaudacionTotal,
        CAST(AVG(recaudacionTotal) OVER () AS DECIMAL(18,2)) AS promedioSemanal,
        CAST(SUM(recaudacionTotal) OVER (ORDER BY inicioSemana
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS DECIMAL(18,2)) AS acumuladoProgresivo
    FROM PagosPorSemana
    ORDER BY inicioSemana;
END
GO

CREATE OR ALTER PROCEDURE reportes.Sp_RecaudacionMesDepartamento
    @Anio        INT = NULL,
    @IdConsorcio INT = NULL,
    @FormatoXML  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SET @Anio = ISNULL(@Anio, YEAR(GETDATE()));
    DECLARE @Desde DATE = DATEFROMPARTS(@Anio, 1, 1);
    DECLARE @Hasta DATE = DATEADD(YEAR, 1, @Desde);

    IF OBJECT_ID('tempdb..#RecaudacionBase') IS NOT NULL DROP TABLE #RecaudacionBase;

    SELECT
        DATEFROMPARTS(YEAR(e.fechaGeneracion), MONTH(e.fechaGeneracion), 1) AS periodoDate,
        CONCAT(ISNULL(uf.piso, 0), uf.departamento)                         AS departamento,
        SUM(p.monto)                                                        AS totalRecaudado
    INTO #RecaudacionBase
    FROM app.Tbl_Pago p
    INNER JOIN app.Tbl_Expensa e 
            ON e.nroExpensa  = p.nroExpensa
           AND e.idConsorcio = p.idConsorcio
    INNER JOIN app.Tbl_UnidadFuncional uf 
            ON uf.idUnidadFuncional = p.nroUnidadFuncional
    WHERE e.fechaGeneracion >= @Desde
      AND e.fechaGeneracion <  @Hasta
      AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
    GROUP BY DATEFROMPARTS(YEAR(e.fechaGeneracion), MONTH(e.fechaGeneracion), 1),
             uf.piso, uf.departamento;

    IF (@FormatoXML = 1)
    BEGIN
        SELECT 
            periodoDate    AS '@Periodo',
            departamento   AS '@Departamento',
            totalRecaudado AS '@Total'
        FROM #RecaudacionBase
        ORDER BY periodoDate, departamento
        FOR XML PATH('Departamento'), ROOT('RecaudacionMensual'), TYPE;
    END
    ELSE
    BEGIN
        SELECT 
            FORMAT(periodoDate, 'yyyy-MM')        AS periodo,
            departamento,
            CAST(totalRecaudado AS DECIMAL(18,2)) AS totalRecaudado
        FROM #RecaudacionBase
        ORDER BY periodoDate, departamento;
    END
END
GO

CREATE OR ALTER PROCEDURE reportes.Sp_RecaudacionPorProcedencia
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL,
    @Agrupacion  VARCHAR(20) = 'MES' -- 'MES' o 'TRIMESTRE'
AS
BEGIN
    SET NOCOUNT ON;

    SET @FechaFin    = CONVERT(date, ISNULL(@FechaFin,    GETDATE()));
    SET @FechaInicio = CONVERT(date, ISNULL(@FechaInicio, DATEADD(YEAR, -1, @FechaFin)));

    ;WITH G AS (
        SELECT g.nroExpensa, g.idConsorcio,
               SUM(CASE WHEN g.tipo='Ordinario'      THEN g.importe ELSE 0 END) AS ord_g,
               SUM(CASE WHEN g.tipo='Extraordinario' THEN g.importe ELSE 0 END) AS ext_g
        FROM app.Tbl_Gasto g
        GROUP BY g.nroExpensa, g.idConsorcio
    ),
    EC AS (
        SELECT ec.nroExpensa, ec.idConsorcio,
               SUM(ISNULL(ec.expensasOrdinarias,0))      AS ord_ec,
               SUM(ISNULL(ec.expensasExtraordinarias,0)) AS ext_ec
        FROM app.Tbl_EstadoCuenta ec
        GROUP BY ec.nroExpensa, ec.idConsorcio
    ),
    Proporciones AS (
        SELECT COALESCE(G.nroExpensa, EC.nroExpensa)   AS nroExpensa,
               COALESCE(G.idConsorcio, EC.idConsorcio) AS idConsorcio,
               COALESCE(NULLIF(G.ord_g,0), EC.ord_ec, 0) AS totalOrdinario,
               COALESCE(NULLIF(G.ext_g,0), EC.ext_ec, 0) AS totalExtraordinario
        FROM G FULL JOIN EC
          ON EC.nroExpensa=G.nroExpensa AND EC.idConsorcio=G.idConsorcio
    ),
    PagosConProporcion AS (
        SELECT
            p.fecha,
            p.monto,
            CASE
              WHEN ISNULL(pr.totalOrdinario,0)+ISNULL(pr.totalExtraordinario,0) > 0
                   THEN CAST(pr.totalOrdinario AS DECIMAL(18,6))
                        / (pr.totalOrdinario+pr.totalExtraordinario)
              ELSE 0.5
            END AS proporcionOrdinaria,
            CASE
              WHEN ISNULL(pr.totalOrdinario,0)+ISNULL(pr.totalExtraordinario,0) > 0
                   THEN CAST(pr.totalExtraordinario AS DECIMAL(18,6))
                        / (pr.totalOrdinario+pr.totalExtraordinario)
              ELSE 0.5
            END AS proporcionExtraordinaria
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_Expensa e
                ON e.nroExpensa  = p.nroExpensa
               AND e.idConsorcio = p.idConsorcio
        LEFT JOIN Proporciones pr
               ON pr.nroExpensa  = e.nroExpensa
              AND pr.idConsorcio = e.idConsorcio
        WHERE p.fecha >= @FechaInicio
          AND p.fecha <  DATEADD(DAY, 1, @FechaFin)
    ),
    RecaudacionTipo AS (
        SELECT
            CASE WHEN @Agrupacion='TRIMESTRE'
                 THEN DATEFROMPARTS(YEAR(fecha), 1 + 3*(DATEPART(QUARTER, fecha)-1), 1)
                 ELSE DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1)
            END AS periodoDate,
            SUM(monto * proporcionOrdinaria)      AS ordinario,
            SUM(monto * proporcionExtraordinaria) AS extraordinario
        FROM PagosConProporcion
        GROUP BY CASE WHEN @Agrupacion='TRIMESTRE'
                      THEN DATEFROMPARTS(YEAR(fecha), 1 + 3*(DATEPART(QUARTER, fecha)-1), 1)
                      ELSE DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1) END
    )
    SELECT
        CASE WHEN @Agrupacion='TRIMESTRE'
             THEN CONCAT(YEAR(periodoDate), '-T', ((DATEPART(MONTH, periodoDate)-1)/3)+1)
             ELSE FORMAT(periodoDate, 'yyyy-MM') END AS periodo,
        CAST(ISNULL(ordinario,0)       AS DECIMAL(18,2)) AS ordinario,
        CAST(ISNULL(extraordinario,0)  AS DECIMAL(18,2)) AS extraordinario,
        CAST(ISNULL(ordinario,0)+ISNULL(extraordinario,0) AS DECIMAL(18,2)) AS total,
        CAST(CASE WHEN (ordinario+extraordinario)>0
                  THEN (ordinario/(ordinario+extraordinario))*100 ELSE 0 END AS DECIMAL(5,2)) AS porcentajeOrdinario,
        CAST(CASE WHEN (ordinario+extraordinario)>0
                  THEN (extraordinario/(ordinario+extraordinario))*100 ELSE 0 END AS DECIMAL(5,2)) AS porcentajeExtraordinario
    FROM RecaudacionTipo
    ORDER BY periodoDate;
END
GO

CREATE OR ALTER PROCEDURE reportes.Sp_Top5MesesGastosIngresos
    @Anio                 INT = NULL,
    @IdConsorcio          INT = NULL,
    @TipoDolar            VARCHAR(50) = 'blue',
    @RefrescarCotizacion  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Desde DATE = CASE WHEN @Anio IS NULL THEN NULL ELSE DATEFROMPARTS(@Anio,1,1) END;
    DECLARE @Hasta DATE = CASE WHEN @Anio IS NULL THEN NULL ELSE DATEADD(YEAR,1,@Desde) END;

    -- **FIX 1: Declarar @cot AL INICIO**
    DECLARE @cot DECIMAL(10,2) = NULL;

    /* (Opcional) refrescar cotización UNA SOLA VEZ */
    IF @RefrescarCotizacion = 1
    BEGIN
        BEGIN TRY
            IF OBJECT_ID('api.Sp_ObtenerCotizacionDolar','P') IS NOT NULL
                EXEC api.Sp_ObtenerCotizacionDolar_Curl @TipoDolar=@TipoDolar, @Verbose=0;
        END TRY
        BEGIN CATCH
            -- Silenciamos fallas de red/API para que el informe no aborte
        END CATCH
    END

    /* **FIX 2: Obtener la última cotización con manejo robusto** */
    SELECT TOP(1) @cot = valorVenta
    FROM api.Tbl_CotizacionDolar WITH (NOLOCK)
    WHERE tipoDolar = @TipoDolar
    ORDER BY fechaConsulta DESC;

    -- **FIX 3: Log de debug (opcional, quitar en producción)**
    IF @cot IS NULL OR @cot <= 0 
    BEGIN
        -- Insertar warning en logs si está disponible
        IF OBJECT_ID('reportes.Sp_LogReporte','P') IS NOT NULL
        BEGIN
            DECLARE @detalle NVARCHAR(4000) = 
                N'TipoDolar=' + @TipoDolar + 
                N', @cot=' + ISNULL(CAST(@cot AS NVARCHAR(20)), N'NULL');
            
            EXEC reportes.Sp_LogReporte 
                @Procedimiento = N'reportes.Sp_Top5MesesGastosIngresos',
                @Tipo = 'WARN',
                @Mensaje = N'No se encontró cotización válida',
                @Detalle = @detalle;
        END
        
        SET @cot = 0;  -- Forzar 0 para que devuelva NULL en resultados
    END

    /* GASTOS TOP 5 */
    ;WITH GastosMensuales AS (
        SELECT
            DATEFROMPARTS(YEAR(g.fechaEmision), MONTH(g.fechaEmision), 1) AS periodoDate,
            SUM(g.importe) AS totalGastos
        FROM app.Tbl_Gasto g
        WHERE (@Desde IS NULL OR g.fechaEmision >= @Desde)
          AND (@Hasta IS NULL OR g.fechaEmision <  @Hasta)
          AND (@IdConsorcio IS NULL OR g.idConsorcio = @IdConsorcio)
        GROUP BY DATEFROMPARTS(YEAR(g.fechaEmision), MONTH(g.fechaEmision), 1)
    )
    SELECT TOP (5)
        'GASTOS' AS tipoMovimiento,
        FORMAT(periodoDate, 'yyyy-MM') AS periodo,
        CAST(totalGastos AS DECIMAL(18,2)) AS montoPesos,
        CASE 
            WHEN @cot > 0 THEN CAST(totalGastos / @cot AS DECIMAL(18,2)) 
            ELSE NULL 
        END AS montoDolares,
        @TipoDolar AS tipoCotizacion,
        @cot AS cotizacionUtilizada  -- **DEBUG: Agregar esta columna temporalmente**
    FROM GastosMensuales
    ORDER BY totalGastos DESC;

    /* INGRESOS TOP 5 */
    ;WITH IngresosMensuales AS (
        SELECT
            DATEFROMPARTS(YEAR(p.fecha), MONTH(p.fecha), 1) AS periodoDate,
            SUM(p.monto) AS totalIngresos
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_Expensa e 
                ON e.nroExpensa  = p.nroExpensa
               AND e.idConsorcio = p.idConsorcio
        WHERE (@Desde IS NULL OR p.fecha >= @Desde)
          AND (@Hasta IS NULL OR p.fecha <  @Hasta)
          AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
        GROUP BY DATEFROMPARTS(YEAR(p.fecha), MONTH(p.fecha), 1)
    )
    SELECT TOP (5)
        'INGRESOS' AS tipoMovimiento,
        FORMAT(periodoDate, 'yyyy-MM') AS periodo,
        CAST(totalIngresos AS DECIMAL(18,2)) AS montoPesos,
        CASE 
            WHEN @cot > 0 THEN CAST(totalIngresos / @cot AS DECIMAL(18,2)) 
            ELSE NULL 
        END AS montoDolares,
        @TipoDolar AS tipoCotizacion,
        @cot AS cotizacionUtilizada  -- **DEBUG: Agregar esta columna temporalmente**
    FROM IngresosMensuales
    ORDER BY totalIngresos DESC;
END
GO

CREATE OR ALTER PROCEDURE reportes.Sp_PropietariosMorosos
    @IdConsorcio INT  = NULL,
    @FechaCorte  DATE = NULL,
    @TopN        INT  = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET @FechaCorte = CONVERT(date, ISNULL(@FechaCorte, GETDATE()));

    /* Propietarios activos por consorcio (si manejás vigencias, descomentar filtros de fecha) */
    ;WITH ufp_activo AS (
        SELECT DISTINCT ufp.idPersona, ufp.idConsorcio
        FROM app.Tbl_UFPersona ufp
        WHERE ufp.esInquilino = 0
        -- AND (@FechaCorte IS NULL OR (ISNULL(ufp.fechaInicio,'19000101') <= @FechaCorte
        --                           AND ISNULL(ufp.fechaFin,'99991231')   >= @FechaCorte))
    ),
    MorosidadPorPersona AS (
        SELECT
            p.idPersona,
            p.nombre,
            p.apellido,

            -- ?? Campos sensibles desencriptados
            CONVERT(INT, seguridad.fn_DesencriptarTexto(p.dniCifrado)) AS dni,
            seguridad.fn_DesencriptarTexto(p.emailCifrado)             AS email,
            seguridad.fn_DesencriptarTexto(p.telefonoCifrado)          AS telefono,

            c.nombre AS consorcio,
            COUNT(DISTINCT ec.nroExpensa) AS expensasImpagas,
            SUM(ec.deuda)                 AS deudaTotal,
            SUM(ec.interesMora)           AS interesTotal,
            SUM(ec.totalAPagar)           AS totalAPagar,
            MAX(e.fechaVto1)              AS ultimoVencimiento,
            DATEDIFF(DAY, MAX(e.fechaVto1), @FechaCorte) AS diasMora
        FROM app.Tbl_EstadoCuenta ec
        INNER JOIN app.Tbl_Expensa e
                ON e.nroExpensa  = ec.nroExpensa
               AND e.idConsorcio = ec.idConsorcio
        INNER JOIN app.Tbl_UnidadFuncional uf
                ON uf.idUnidadFuncional = ec.nroUnidadFuncional
               AND uf.idConsorcio       = ec.idConsorcio
        INNER JOIN app.Tbl_Persona p
                ON p.CBU_CVU = uf.CBU_CVU              -- persona ? UF por CBU/CVU
        INNER JOIN ufp_activo u
                ON u.idPersona   = p.idPersona         -- validar que sea propietario
               AND u.idConsorcio = ec.idConsorcio      -- y del mismo consorcio
        INNER JOIN app.Tbl_Consorcio c
                ON c.idConsorcio = ec.idConsorcio
        WHERE ec.deuda > 0
          AND e.fechaVto1 < @FechaCorte
          AND (@IdConsorcio IS NULL OR ec.idConsorcio = @IdConsorcio)
        GROUP BY
            p.idPersona,
            p.nombre,
            p.apellido,
            p.dniCifrado,
            p.emailCifrado,
            p.telefonoCifrado,
            c.nombre
    )
    SELECT TOP (@TopN)
        idPersona,
        CONCAT(apellido, ', ', nombre) AS nombreCompleto,
        dni, email, telefono,
        consorcio,
        deudaTotal, interesTotal, totalAPagar,
        expensasImpagas,
        ultimoVencimiento,
        diasMora,
        CASE 
            WHEN diasMora > 180 THEN 'CRITICO'
            WHEN diasMora >  90 THEN 'ALTO'
            WHEN diasMora >  30 THEN 'MEDIO'
            ELSE 'BAJO'
        END AS nivelMorosidad
    FROM MorosidadPorPersona
    ORDER BY totalAPagar DESC, diasMora DESC;
END
GO

CREATE OR ALTER PROCEDURE reportes.Sp_DiasEntrePagos
    @IdConsorcio INT  = NULL,
    @FechaInicio DATE = NULL,
    @FechaFin    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @FechaFin    = CONVERT(date, ISNULL(@FechaFin,    GETDATE()));
    SET @FechaInicio = CONVERT(date, ISNULL(@FechaInicio, DATEADD(YEAR, -1, @FechaFin)));

    ;WITH PagosOrdenados AS (
        SELECT
            c.nombre AS consorcio,
            CONCAT('UF-', uf.idUnidadFuncional, ' (Piso ', ISNULL(uf.piso, 0), uf.departamento, ')') AS unidadFuncional,
            p.fecha AS fechaPago,
            LAG(p.fecha) OVER (PARTITION BY uf.idUnidadFuncional ORDER BY p.fecha) AS pagoAnterior,
            p.monto
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_UnidadFuncional uf 
                ON uf.idUnidadFuncional = p.nroUnidadFuncional
        INNER JOIN app.Tbl_Consorcio c 
                ON c.idConsorcio = uf.idConsorcio
        WHERE p.fecha >= @FechaInicio
          AND p.fecha <  DATEADD(DAY, 1, @FechaFin)
          AND (@IdConsorcio IS NULL OR uf.idConsorcio = @IdConsorcio)
    )
    SELECT
        consorcio       AS '@Consorcio',
        unidadFuncional AS '@UnidadFuncional',
        fechaPago       AS 'FechaPago',
        pagoAnterior    AS 'PagoAnterior',
        CASE WHEN pagoAnterior IS NOT NULL 
             THEN DATEDIFF(DAY, pagoAnterior, fechaPago) END AS 'DiasEntrePagos',
        monto           AS 'Monto'
    FROM PagosOrdenados
    WHERE pagoAnterior IS NOT NULL
    ORDER BY unidadFuncional, fechaPago
    FOR XML PATH('Pago'), ROOT('HistorialPagos');
END
GO