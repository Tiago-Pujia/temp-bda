USE Com5600G13;
GO

/* =========================================================================
   REPORTE 1: FLUJO DE CAJA SEMANAL
   Recaudación por pagos ordinarios y extraordinarios, promedio y acumulado
   
   Parámetros:
   - @FechaInicio: Fecha de inicio del análisis
   - @FechaFin: Fecha de fin del análisis
   - @IdConsorcio: Filtro por consorcio (NULL = todos)
========================================================================= */
CREATE OR ALTER PROCEDURE reportes.Sp_FlujoCajaSemanal
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL,
    @IdConsorcio INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Valores por defecto: últimos 3 meses
    SET @FechaInicio = ISNULL(@FechaInicio, DATEADD(MONTH, -3, GETDATE()));
    SET @FechaFin = ISNULL(@FechaFin, GETDATE());
    
    ;WITH GastosPorExpensa AS (
        -- Calcular proporción de gastos ordinarios vs extraordinarios por expensa
        SELECT
            nroExpensa,
            idConsorcio,
            SUM(CASE WHEN tipo = 'Ordinario' THEN importe ELSE 0 END) AS totalOrdinario,
            SUM(CASE WHEN tipo = 'Extraordinario' THEN importe ELSE 0 END) AS totalExtraordinario,
            SUM(importe) AS totalGastos
        FROM app.Tbl_Gasto
        GROUP BY nroExpensa, idConsorcio
    ),
    PagosPorSemana AS (
        SELECT
            DATEPART(YEAR, p.fecha) AS anio,
            DATEPART(WEEK, p.fecha) AS semana,
            DATEADD(DAY, 1 - DATEPART(WEEKDAY, p.fecha), p.fecha) AS inicioSemana,
            -- Distribuir pagos según proporción de gastos en la expensa
            SUM(p.monto * 
                CASE 
                    WHEN ISNULL(g.totalGastos, 0) = 0 THEN 0.5
                    ELSE g.totalOrdinario / g.totalGastos
                END
            ) AS recaudacionOrdinaria,
            SUM(p.monto * 
                CASE 
                    WHEN ISNULL(g.totalGastos, 0) = 0 THEN 0.5
                    ELSE g.totalExtraordinario / g.totalGastos
                END
            ) AS recaudacionExtraordinaria,
            SUM(p.monto) AS recaudacionTotal
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_Expensa e ON e.nroExpensa = p.nroExpensa
        LEFT JOIN GastosPorExpensa g ON g.nroExpensa = e.nroExpensa AND g.idConsorcio = e.idConsorcio
        WHERE p.fecha BETWEEN @FechaInicio AND @FechaFin
          AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
        GROUP BY 
            DATEPART(YEAR, p.fecha),
            DATEPART(WEEK, p.fecha),
            DATEADD(DAY, 1 - DATEPART(WEEKDAY, p.fecha), p.fecha)
    )
    SELECT
        anio,
        semana,
        inicioSemana,
        CAST(recaudacionOrdinaria AS DECIMAL(18,2)) AS recaudacionOrdinaria,
        CAST(recaudacionExtraordinaria AS DECIMAL(18,2)) AS recaudacionExtraordinaria,
        CAST(recaudacionTotal AS DECIMAL(18,2)) AS recaudacionTotal,
        -- Promedio del periodo
        CAST(AVG(recaudacionTotal) OVER () AS DECIMAL(18,2)) AS promedioSemanal,
        -- Acumulado progresivo
        CAST(SUM(recaudacionTotal) OVER (ORDER BY anio, semana 
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS DECIMAL(18,2)) AS acumuladoProgresivo
    FROM PagosPorSemana
    ORDER BY anio, semana;
END
GO

/* =========================================================================
   REPORTE 2: RECAUDACIÓN POR MES Y DEPARTAMENTO (TABLA CRUZADA)
   
   Parámetros:
   - @Anio: Año a analizar
   - @IdConsorcio: Filtro por consorcio (NULL = todos)
   - @FormatoXML: 1 para devolver en XML
========================================================================= */
CREATE OR ALTER PROCEDURE reportes.Sp_RecaudacionMesDepartamento
    @Anio INT = NULL,
    @IdConsorcio INT = NULL,
    @FormatoXML BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    
    SET @Anio = ISNULL(@Anio, YEAR(GETDATE()));
    
    ;WITH RecaudacionBase AS (
        SELECT
            MONTH(e.fechaGeneracion) AS mes,
            CONCAT(ISNULL(uf.piso, 0), uf.departamento) AS departamento,
            SUM(p.monto) AS totalRecaudado
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_Expensa e ON e.nroExpensa = p.nroExpensa
        INNER JOIN app.Tbl_UnidadFuncional uf ON uf.idUnidadFuncional = p.nroUnidadFuncional
        WHERE YEAR(e.fechaGeneracion) = @Anio
          AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
        GROUP BY MONTH(e.fechaGeneracion), uf.piso, uf.departamento
    )
    SELECT 
        mes,
        departamento,
        totalRecaudado
    FROM RecaudacionBase
    ORDER BY mes, departamento
    FOR XML PATH('Departamento'), ROOT('RecaudacionMensual'), TYPE;
END
GO

/* =========================================================================
   REPORTE 3: RECAUDACIÓN POR PROCEDENCIA (ORDINARIO/EXTRAORDINARIO)
   Tabla cruzada por periodo
   
   Parámetros:
   - @FechaInicio: Fecha de inicio
   - @FechaFin: Fecha de fin
   - @Agrupacion: 'MES' o 'TRIMESTRE'
   
   Lógica: Calcula la proporción de gastos ordinarios vs extraordinarios
   en cada expensa y distribuye los pagos proporcionalmente
========================================================================= */
CREATE OR ALTER PROCEDURE reportes.Sp_RecaudacionPorProcedencia
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL,
    @Agrupacion VARCHAR(20) = 'MES'
AS
BEGIN
    SET NOCOUNT ON;
    
    SET @FechaInicio = ISNULL(@FechaInicio, DATEADD(YEAR, -1, GETDATE()));
    SET @FechaFin = ISNULL(@FechaFin, GETDATE());
    
    ;WITH GastosPorExpensa AS (
        -- Calcular totales de gastos ordinarios y extraordinarios por expensa
        SELECT
            nroExpensa,
            idConsorcio,
            SUM(CASE WHEN tipo = 'Ordinario' THEN importe ELSE 0 END) AS totalOrdinario,
            SUM(CASE WHEN tipo = 'Extraordinario' THEN importe ELSE 0 END) AS totalExtraordinario,
            SUM(importe) AS totalGastos
        FROM app.Tbl_Gasto
        GROUP BY nroExpensa, idConsorcio
    ),
    PagosConProporcion AS (
        -- Asociar cada pago con la proporción de gastos de su expensa
        SELECT
            p.fecha,
            p.monto,
            CASE 
                WHEN ISNULL(g.totalGastos, 0) = 0 THEN 0.5  -- Si no hay gastos, 50/50
                ELSE g.totalOrdinario / g.totalGastos
            END AS proporcionOrdinaria,
            CASE 
                WHEN ISNULL(g.totalGastos, 0) = 0 THEN 0.5
                ELSE g.totalExtraordinario / g.totalGastos
            END AS proporcionExtraordinaria
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_Expensa e ON e.nroExpensa = p.nroExpensa
        LEFT JOIN GastosPorExpensa g ON g.nroExpensa = e.nroExpensa AND g.idConsorcio = e.idConsorcio
        WHERE p.fecha BETWEEN @FechaInicio AND @FechaFin
    ),
    RecaudacionTipo AS (
        -- Distribuir el monto de cada pago según la proporción
        SELECT
            CASE 
                WHEN @Agrupacion = 'TRIMESTRE' THEN 
                    CONCAT(YEAR(fecha), '-T', DATEPART(QUARTER, fecha))
                ELSE 
                    FORMAT(fecha, 'yyyy-MM')
            END AS periodo,
            SUM(monto * proporcionOrdinaria) AS ordinario,
            SUM(monto * proporcionExtraordinaria) AS extraordinario
        FROM PagosConProporcion
        GROUP BY 
            CASE 
                WHEN @Agrupacion = 'TRIMESTRE' THEN 
                    CONCAT(YEAR(fecha), '-T', DATEPART(QUARTER, fecha))
                ELSE 
                    FORMAT(fecha, 'yyyy-MM')
            END
    )
    SELECT
        periodo,
        CAST(ISNULL(ordinario, 0) AS DECIMAL(18,2)) AS ordinario,
        CAST(ISNULL(extraordinario, 0) AS DECIMAL(18,2)) AS extraordinario,
        CAST(ISNULL(ordinario, 0) + ISNULL(extraordinario, 0) AS DECIMAL(18,2)) AS total,
        CAST(CASE 
            WHEN (ordinario + extraordinario) > 0 
            THEN (ordinario / (ordinario + extraordinario)) * 100 
            ELSE 0 
        END AS DECIMAL(5,2)) AS porcentajeOrdinario,
        CAST(CASE 
            WHEN (ordinario + extraordinario) > 0 
            THEN (extraordinario / (ordinario + extraordinario)) * 100 
            ELSE 0 
        END AS DECIMAL(5,2)) AS porcentajeExtraordinario
    FROM RecaudacionTipo
    ORDER BY periodo;
END
GO

/* =========================================================================
   REPORTE 4: TOP 5 MESES DE MAYORES GASTOS Y MAYORES INGRESOS
   
   Parámetros:
   - @Anio: Año a analizar (NULL = todos los años)
   - @IdConsorcio: Filtro por consorcio
   - @TipoDolar: Tipo de cotización para conversión (blue, oficial)
========================================================================= */
CREATE OR ALTER PROCEDURE reportes.Sp_Top5MesesGastosIngresos
    @Anio INT = NULL,
    @IdConsorcio INT = NULL,
    @TipoDolar VARCHAR(50) = 'blue'
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Actualizar cotización del dólar
    EXEC app.Sp_ObtenerCotizacionDolar @TipoDolar = @TipoDolar, @Verbose = 0;
    
    -- TOP 5 Meses con mayores GASTOS
    ;WITH GastosMensuales AS (
        SELECT
            FORMAT(g.fechaEmision, 'yyyy-MM') AS periodo,
            SUM(g.importe) AS totalGastos,
            app.fn_PesosADolares(SUM(g.importe), @TipoDolar) AS totalGastosUSD
        FROM app.Tbl_Gasto g
        WHERE (@Anio IS NULL OR YEAR(g.fechaEmision) = @Anio)
          AND (@IdConsorcio IS NULL OR g.idConsorcio = @IdConsorcio)
        GROUP BY FORMAT(g.fechaEmision, 'yyyy-MM')
    )
    SELECT TOP 5
        'GASTOS' AS tipoMovimiento,
        periodo,
        totalGastos AS montoPesos,
        totalGastosUSD AS montoDolares,
        @TipoDolar AS tipoCotizacion
    FROM GastosMensuales
    ORDER BY totalGastos DESC;
    
    -- TOP 5 Meses con mayores INGRESOS
    ;WITH IngresosMensuales AS (
        SELECT
            FORMAT(p.fecha, 'yyyy-MM') AS periodo,
            SUM(p.monto) AS totalIngresos,
            app.fn_PesosADolares(SUM(p.monto), @TipoDolar) AS totalIngresosUSD
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_Expensa e ON e.nroExpensa = p.nroExpensa
        WHERE (@Anio IS NULL OR YEAR(p.fecha) = @Anio)
          AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
        GROUP BY FORMAT(p.fecha, 'yyyy-MM')
    )
    SELECT TOP 5
        'INGRESOS' AS tipoMovimiento,
        periodo,
        totalIngresos AS montoPesos,
        totalIngresosUSD AS montoDolares,
        @TipoDolar AS tipoCotizacion
    FROM IngresosMensuales
    ORDER BY totalIngresos DESC;
END
GO

/* =========================================================================
   REPORTE 5: TOP 3 PROPIETARIOS CON MAYOR MOROSIDAD
   
   Parámetros:
   - @IdConsorcio: Filtro por consorcio
   - @FechaCorte: Fecha de corte para calcular morosidad
   - @TopN: Cantidad de morosos a mostrar (default 3)
========================================================================= */
CREATE OR ALTER PROCEDURE reportes.Sp_PropietariosMorosos
    @IdConsorcio INT = NULL,
    @FechaCorte DATE = NULL,
    @TopN INT = 3
AS
BEGIN
    SET NOCOUNT ON;
    
    SET @FechaCorte = ISNULL(@FechaCorte, GETDATE());
    
    ;WITH MorosidadPorPersona AS (
        SELECT
            p.idPersona,
            p.nombre,
            p.apellido,
            p.dni,
            p.email,
            p.telefono,
            c.nombre AS consorcio,
            COUNT(DISTINCT ec.nroExpensa) AS expensasImpagas,
            SUM(ec.deuda) AS deudaTotal,
            SUM(ec.interesMora) AS interesTotal,
            SUM(ec.totalAPagar) AS totalAPagar,
            MAX(e.fechaVto1) AS ultimoVencimiento,
            DATEDIFF(DAY, MAX(e.fechaVto1), @FechaCorte) AS diasMora
        FROM app.Tbl_Persona p
        INNER JOIN app.Tbl_UFPersona ufp ON ufp.idPersona = p.idPersona
        INNER JOIN app.Tbl_EstadoCuenta ec 
            ON ec.nroUnidadFuncional = ufp.idUnidadFuncional 
            AND ec.idConsorcio = ufp.idConsorcio
        INNER JOIN app.Tbl_Expensa e 
            ON e.nroExpensa = ec.nroExpensa 
            AND e.idConsorcio = ec.idConsorcio
        INNER JOIN app.Tbl_Consorcio c ON c.idConsorcio = e.idConsorcio
        WHERE ufp.esInquilino = 0  -- Solo propietarios
          AND ec.deuda > 0
          AND e.fechaVto1 < @FechaCorte
          AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
        GROUP BY 
            p.idPersona, p.nombre, p.apellido, p.dni, 
            p.email, p.telefono, c.nombre
    )
    SELECT TOP (@TopN)
        idPersona,
        CONCAT(apellido, ', ', nombre) AS nombreCompleto,
        dni,
        email,
        telefono,
        consorcio,
        expensasImpagas,
        deudaTotal,
        interesTotal,
        totalAPagar,
        ultimoVencimiento,
        diasMora,
        CASE 
            WHEN diasMora > 180 THEN 'CRITICO'
            WHEN diasMora > 90 THEN 'ALTO'
            WHEN diasMora > 30 THEN 'MEDIO'
            ELSE 'BAJO'
        END AS nivelMorosidad
    FROM MorosidadPorPersona
    ORDER BY totalAPagar DESC, diasMora DESC;
END
GO

/* =========================================================================
   REPORTE 6: FECHAS DE PAGOS Y DÍAS ENTRE PAGOS POR UNIDAD FUNCIONAL
   Formato XML
   
   Parámetros:
   - @IdConsorcio: Filtro por consorcio
   - @FechaInicio: Fecha de inicio
   - @FechaFin: Fecha de fin
========================================================================= */
CREATE OR ALTER PROCEDURE reportes.Sp_DiasEntrePagos
    @IdConsorcio INT = NULL,
    @FechaInicio DATE = NULL,
    @FechaFin DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    SET @FechaInicio = ISNULL(@FechaInicio, DATEADD(YEAR, -1, GETDATE()));
    SET @FechaFin = ISNULL(@FechaFin, GETDATE());
    
    ;WITH PagosOrdenados AS (
        SELECT
            c.nombre AS consorcio,
            CONCAT('UF-', uf.idUnidadFuncional, ' (Piso ', 
                   ISNULL(uf.piso, 0), uf.departamento, ')') AS unidadFuncional,
            p.fecha AS fechaPago,
            LAG(p.fecha) OVER (
                PARTITION BY uf.idUnidadFuncional 
                ORDER BY p.fecha
            ) AS pagoAnterior,
            p.monto
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_UnidadFuncional uf 
            ON uf.idUnidadFuncional = p.nroUnidadFuncional
        INNER JOIN app.Tbl_Consorcio c ON c.idConsorcio = uf.idConsorcio
        WHERE p.fecha BETWEEN @FechaInicio AND @FechaFin
          AND (@IdConsorcio IS NULL OR uf.idConsorcio = @IdConsorcio)
    )
    SELECT
        consorcio AS '@Consorcio',
        unidadFuncional AS '@UnidadFuncional',
        fechaPago AS 'FechaPago',
        pagoAnterior AS 'PagoAnterior',
        CASE 
            WHEN pagoAnterior IS NOT NULL 
            THEN DATEDIFF(DAY, pagoAnterior, fechaPago)
            ELSE NULL
        END AS 'DiasEntrePagos',
        monto AS 'Monto'
    FROM PagosOrdenados
    WHERE pagoAnterior IS NOT NULL
    ORDER BY unidadFuncional, fechaPago
    FOR XML PATH('Pago'), ROOT('HistorialPagos');
END
GO