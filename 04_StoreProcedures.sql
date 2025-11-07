USE master
GO

EXEC sys.sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sys.sp_configure 'Ad Hoc Distributed Queries', 1;
RECONFIGURE;

EXEC dbo.sp_MSset_oledb_prop N'Microsoft.ACE.OLEDB.16.0', N'AllowInProcess', 1;
EXEC dbo.sp_MSset_oledb_prop N'Microsoft.ACE.OLEDB.16.0', N'DynamicParameters', 1;

USE Com5600G13;
GO

-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE reportes.Sp_LogReporte
    @Procedimiento SYSNAME,
    @Tipo          VARCHAR(30),            -- INFO | WARN | ERROR
    @Mensaje       NVARCHAR(4000) = NULL,
    @Detalle       NVARCHAR(4000) = NULL,
    @RutaArchivo   NVARCHAR(4000) = NULL, -- archivo de datos
    @RutaLog       NVARCHAR(4000) = NULL  -- archivo .log (opcional)
AS
BEGIN
    SET NOCOUNT ON;

    -- 1) Guardar siempre en la tabla
    INSERT INTO reportes.logsReportes(procedimiento, tipo, mensaje, detalle, rutaArchivo, rutaLog)
    VALUES (@Procedimiento, @Tipo, @Mensaje, @Detalle, @RutaArchivo, @RutaLog);

    -- 2) Si pidieron archivo de log, intento escribir una línea
    IF @RutaLog IS NOT NULL
    BEGIN
        DECLARE @linea NVARCHAR(4000);
        DECLARE @cmd   NVARCHAR(4000);

        -- Armo la línea de texto (UTC yyyy-mm-dd hh:mi:ss)
        SET @linea = CONVERT(nvarchar(19), GETUTCDATE(), 120) + N' | ' +
                     ISNULL(@Procedimiento, N'') + N' | ' +
                     ISNULL(@Tipo, N'') + N' | ' +
                     ISNULL(@Mensaje, N'');

        IF @Detalle IS NOT NULL
            SET @linea = @linea + N' | ' + @Detalle;

        IF @RutaArchivo IS NOT NULL
            SET @linea = @linea + N' | src=' + @RutaArchivo;

        -- Evito comillas dobles en el echo (bien simple)
        SET @linea = REPLACE(@linea, N'"', N'''');

        SET @cmd = N'cmd /c echo "' + @linea + N'" >> "' + @RutaLog + N'"';

        BEGIN TRY
            EXEC master..xp_cmdshell @cmd, NO_OUTPUT;
        END TRY
        BEGIN CATCH
            -- Si no se pudo escribir el archivo, dejo un WARN en tabla y sigo
            INSERT INTO reportes.logsReportes(procedimiento, tipo, mensaje, detalle, rutaArchivo, rutaLog)
            VALUES (@Procedimiento, 'WARN', 'No se pudo escribir en archivo de log', ERROR_MESSAGE(), @RutaArchivo, @RutaLog);
        END CATCH
    END
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarConsorciosDesdeExcel
    @RutaArchivo NVARCHAR(4000),                 -- (xlsx/xls) OBLIGATORIO
    @Hoja        NVARCHAR(128) = N'consorcios$', -- hoja de Excel
    @HDR         BIT = 1,                        -- 1 = primera fila tiene encabezados
    @LogPath     NVARCHAR(4000) = NULL,          -- ej: 'C:\logs\consorcios.log'
    @Verbose     BIT = 0                         -- 1 = escribe logs INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarConsorciosDesdeExcel';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio de proceso', NULL, @RutaArchivo, @LogPath;

        -- 1) Normalización de parámetros
        DECLARE @HojaNormalizada NVARCHAR(128) = CASE WHEN RIGHT(@Hoja,1)=N'$' THEN @Hoja ELSE @Hoja + N'$' END;
        DECLARE @EncabezadoTexto NVARCHAR(3) = CASE WHEN @HDR = 1 THEN N'YES' ELSE N'NO' END;

        -- 2) Tabla temporal cruda (columnas iguales al Excel)
        IF OBJECT_ID('tempdb..#XlsCrudo') IS NOT NULL DROP TABLE #XlsCrudo;
        CREATE TABLE #XlsCrudo
        (
            [Nombre del consorcio] NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [Domicilio]            NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [m2 totales]           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        -- 3) OPENROWSET (SQL dinámico mínimo)
        DECLARE @Proveedor NVARCHAR(4000) =
            N'Excel 12.0 Xml;HDR=' + @EncabezadoTexto + N';IMEX=1;Database=' + REPLACE(@RutaArchivo, N'''', N'''''');
        DECLARE @Consulta  NVARCHAR(4000) =
            N'SELECT [Nombre del consorcio], [Domicilio], [m2 totales] FROM [' + @HojaNormalizada + N']';

        DECLARE @Sql NVARCHAR(MAX) = N'
INSERT INTO #XlsCrudo([Nombre del consorcio],[Domicilio],[m2 totales])
SELECT [Nombre del consorcio],[Domicilio],[m2 totales]
FROM OPENROWSET(
    ''Microsoft.ACE.OLEDB.16.0'',
    ' + QUOTENAME(@Proveedor,'''') + ',
    ' + QUOTENAME(@Consulta, '''') + '
);';

        EXEC sys.sp_executesql @Sql;

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasLeidas INT = (SELECT COUNT(*) FROM #XlsCrudo);
            DECLARE @DetalleLeidas NVARCHAR(4000) = N'filas=' + CONVERT(NVARCHAR(20), @FilasLeidas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Leídas filas desde Excel', @DetalleLeidas, @RutaArchivo, @LogPath;
        END

        -- 4) Staging tipado/validado (usa helpers)
        IF OBJECT_ID('tempdb..#ConsorcioStaging') IS NOT NULL DROP TABLE #ConsorcioStaging;
        CREATE TABLE #ConsorcioStaging
        (
            nombre          VARCHAR(50)     COLLATE DATABASE_DEFAULT NOT NULL,
            direccion       VARCHAR(100)    COLLATE DATABASE_DEFAULT NULL,
            superficieTotal DECIMAL(10,2)   NULL
        );

        INSERT INTO #ConsorcioStaging (nombre, direccion, superficieTotal)
        SELECT
            nombre          = importacion.fn_LimpiarTexto([Nombre del consorcio], 50),
            direccion       = importacion.fn_LimpiarTexto([Domicilio], 100),
            superficieTotal = importacion.fn_A_Decimal([m2 totales])
        FROM #XlsCrudo
        WHERE importacion.fn_LimpiarTexto([Nombre del consorcio], 50) IS NOT NULL;

        -- 5) Insert directo evitando duplicados (nombre + dirección)
        DECLARE @Insertadas INT = 0;

        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT s.nombre, s.direccion, s.superficieTotal
        FROM #ConsorcioStaging s
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM app.Tbl_Consorcio c
            WHERE c.nombre COLLATE DATABASE_DEFAULT = s.nombre
              AND ISNULL(c.direccion,'') COLLATE DATABASE_DEFAULT = ISNULL(s.direccion,'')
        );

        SET @Insertadas = @@ROWCOUNT;

        -- 6) Resumen + log final
        DECLARE @TotalExcel INT = (SELECT COUNT(*) FROM #XlsCrudo);
        DECLARE @Procesadas INT = (SELECT COUNT(*) FROM #ConsorcioStaging);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetalleFin NVARCHAR(4000) =
                N'insertadas=' + CONVERT(NVARCHAR(20), @Insertadas) +
                N'; procesadas=' + CONVERT(NVARCHAR(20), @Procesadas) +
                N'; total_excel=' + CONVERT(NVARCHAR(20), @TotalExcel);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK', @DetalleFin, @RutaArchivo, @LogPath;
        END

        SELECT
            total_excel      = @TotalExcel,
            procesadas_stg   = @Procesadas,
            insertadas_final = @Insertadas,
            mensaje          = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MensajeError  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @NumeroError   INT            = ERROR_NUMBER();
        DECLARE @LineaError    INT            = ERROR_LINE();

        DECLARE @DetalleError NVARCHAR(4000) =
            N'Falla en importación (' + CONVERT(NVARCHAR(20), @NumeroError) +
            N' en línea ' + CONVERT(NVARCHAR(20), @LineaError) + N')';

        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetalleError,
            @Detalle       = @MensajeError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;

        ;THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE app.Sp_ActualizarEstadoCuentaDesdeGastos
  @idConsorcio  INT   = NULL,   -- NULL = todos
  @nroExpensa   INT   = NULL,   -- NULL = todas
  @desdeFecha   DATE  = NULL,   -- filtra por fechaGeneracion de la expensa
  @hastaFecha   DATE  = NULL,
  @incluirDummy BIT   = 0       -- 0 = ignora expensas 1900-01-01 o monto 0
AS
BEGIN
  SET NOCOUNT ON;

  -- Filtrado de expensas materializado (persistente para varias sentencias)
  IF OBJECT_ID('tempdb..#FilExp') IS NOT NULL DROP TABLE #FilExp;

  SELECT
      e.idConsorcio,
      e.nroExpensa,
      e.fechaGeneracion,
      e.fechaVto1
  INTO #FilExp
  FROM app.Tbl_Expensa e
  WHERE (@idConsorcio IS NULL OR e.idConsorcio = @idConsorcio)
    AND (@nroExpensa  IS NULL OR e.nroExpensa  = @nroExpensa)
    AND (@desdeFecha  IS NULL OR e.fechaGeneracion >= @desdeFecha)
    AND (@hastaFecha  IS NULL OR e.fechaGeneracion <= @hastaFecha)
    AND (
         @incluirDummy = 1
         OR (e.fechaGeneracion <> '19000101' AND ISNULL(e.montoTotal,0) <> 0)
    );

  -- Si no hay nada que recalcular, salir
  IF NOT EXISTS (SELECT 1 FROM #FilExp) RETURN;

  ---------------------------------------------------------------------------
  -- (0) Asegurar esqueleto UF×Expensa en EstadoCuenta para este filtro
  ---------------------------------------------------------------------------
  INSERT INTO app.Tbl_EstadoCuenta
    (idConsorcio, nroUnidadFuncional, nroExpensa,
     saldoAnterior, expensasOrdinarias, expensasExtraordinarias,
     pagoRecibido, interesMora, deuda, totalAPagar, fecha)
  SELECT
     f.idConsorcio,
     uf.idUnidadFuncional,
     f.nroExpensa,
     0,0,0,0,0,0,0,
     ISNULL(f.fechaVto1, f.fechaGeneracion)
  FROM #FilExp f
  JOIN app.Tbl_UnidadFuncional uf
       ON uf.idConsorcio = f.idConsorcio
  LEFT JOIN app.Tbl_EstadoCuenta ec
       ON ec.idConsorcio = uf.idConsorcio
      AND ec.nroUnidadFuncional = uf.idUnidadFuncional
      AND ec.nroExpensa = f.nroExpensa
  WHERE ec.idEstadoCuenta IS NULL;

  ---------------------------------------------------------------------------
  -- (1) Normalizar la fecha de EC con la de la expensa
  ---------------------------------------------------------------------------
  UPDATE ec
SET ec.fecha = ISNULL(e.fechaVto1, e.fechaGeneracion)
FROM app.Tbl_EstadoCuenta ec
JOIN app.Tbl_Expensa e
  ON e.idConsorcio=ec.idConsorcio AND e.nroExpensa=ec.nroExpensa
WHERE (@idConsorcio IS NULL OR e.idConsorcio=@idConsorcio)
  AND (@nroExpensa IS NULL OR e.nroExpensa=@nroExpensa)
  AND (@desdeFecha IS NULL OR e.fechaGeneracion>=@desdeFecha)
  AND (@hastaFecha IS NULL OR e.fechaGeneracion<=@hastaFecha);

  ---------------------------------------------------------------------------
  -- (2) Totales por expensa y prorrateo por % de la UF
  ---------------------------------------------------------------------------
  ;WITH Tot AS (
    SELECT g.idConsorcio, g.nroExpensa,
           SUM(CASE WHEN g.tipo='Ordinario'      THEN g.importe ELSE 0 END) AS totOrd,
           SUM(CASE WHEN g.tipo='Extraordinario' THEN g.importe ELSE 0 END) AS totExt
    FROM app.Tbl_Gasto g
    GROUP BY g.idConsorcio, g.nroExpensa
  ),
  SumUF AS (
    SELECT idConsorcio,
           SUM(CAST(porcentaje AS DECIMAL(18,6))) AS sumPorc
    FROM app.Tbl_UnidadFuncional
    GROUP BY idConsorcio
  )
  UPDATE ec
  SET ec.expensasOrdinarias      = ROUND(ISNULL(t.totOrd,0) * (uf.porcentaje / NULLIF(su.sumPorc,0)), 2),
      ec.expensasExtraordinarias = ROUND(ISNULL(t.totExt,0) * (uf.porcentaje / NULLIF(su.sumPorc,0)), 2),
      ec.pagoRecibido            = ISNULL(ec.pagoRecibido,0),
      ec.interesMora             = ISNULL(ec.interesMora,0),
      ec.saldoAnterior           = ISNULL(ec.saldoAnterior,0)
  FROM app.Tbl_EstadoCuenta ec
  JOIN app.Tbl_UnidadFuncional uf
    ON uf.idUnidadFuncional = ec.nroUnidadFuncional AND uf.idConsorcio = ec.idConsorcio
  JOIN #FilExp f
    ON f.idConsorcio = ec.idConsorcio AND f.nroExpensa = ec.nroExpensa
  LEFT JOIN Tot t
    ON t.idConsorcio = ec.idConsorcio AND t.nroExpensa = ec.nroExpensa
  LEFT JOIN SumUF su
    ON su.idConsorcio = ec.idConsorcio;

  ---------------------------------------------------------------------------
  -- (3) Encadenar saldoAnterior por UF (orden cronológico)
  ---------------------------------------------------------------------------
  ;WITH Base AS (
    SELECT ec.idEstadoCuenta,
           ec.idConsorcio, ec.nroUnidadFuncional, ec.nroExpensa,
           e.fechaGeneracion,
           (ISNULL(ec.expensasOrdinarias,0)
          + ISNULL(ec.expensasExtraordinarias,0)
          + ISNULL(ec.interesMora,0)
          - ISNULL(ec.pagoRecibido,0)) AS totalMesSinSaldo
    FROM app.Tbl_EstadoCuenta ec
    JOIN app.Tbl_Expensa e
      ON e.idConsorcio = ec.idConsorcio
     AND e.nroExpensa  = ec.nroExpensa
    JOIN #FilExp f
      ON f.idConsorcio = e.idConsorcio
     AND f.nroExpensa  = e.nroExpensa
  ),
  Ord AS (
    SELECT b.*,
           LAG(b.totalMesSinSaldo, 1, 0) OVER (
             PARTITION BY b.idConsorcio, b.nroUnidadFuncional
             ORDER BY b.fechaGeneracion, b.nroExpensa
           ) AS saldoAntCalc
    FROM Base b
  )
  UPDATE ec
  SET ec.saldoAnterior = o.saldoAntCalc
  FROM app.Tbl_EstadoCuenta ec
  JOIN Ord o
    ON o.idEstadoCuenta = ec.idEstadoCuenta;

  ---------------------------------------------------------------------------
  -- (4) Recalcular deuda y total a pagar
  ---------------------------------------------------------------------------
  ---------------------------------------------------------------------------
  -- (4) Calcular interés por mora (si hay deuda y pasó vencimiento)
  ---------------------------------------------------------------------------
  ;WITH AggPagos AS (
    SELECT 
        p.idEstadoCuenta,
        SUM(p.monto) AS montoPagado,
        MAX(p.fecha) AS fechaUltimoPago
    FROM app.Tbl_Pago p
    WHERE p.idEstadoCuenta IS NOT NULL
    GROUP BY p.idEstadoCuenta
  )
  UPDATE ec
  SET 
      -- Recalcular pago recibido desde Tbl_Pago
      ec.pagoRecibido = ISNULL(ap.montoPagado, 0),
      
      -- Base del mes (ordinarias + extraordinarias)
      ec.deuda = CASE 
          WHEN (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
               <= ISNULL(ap.montoPagado, 0) 
          THEN 0
          ELSE (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
               - ISNULL(ap.montoPagado, 0)
      END,
      
      -- Interés por mora según fecha de pago vs vencimientos
      ec.interesMora = CASE
          -- Si cubrió todo, no hay mora
          WHEN (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
               <= ISNULL(ap.montoPagado, 0) THEN 0
          
          -- Si no hay pagos, calcular mora según fecha actual vs vencimientos
          WHEN ap.montoPagado IS NULL THEN
              CASE 
                  WHEN GETDATE() <= ex.fechaVto1 THEN 0
                  WHEN GETDATE() > ex.fechaVto1 
                       AND (ex.fechaVto2 IS NULL OR GETDATE() <= ex.fechaVto2)
                       THEN ROUND(0.02 * (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)), 2)
                  WHEN ex.fechaVto2 IS NOT NULL AND GETDATE() > ex.fechaVto2
                       THEN ROUND(0.05 * (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)), 2)
                  ELSE 0
              END
          
          -- Si hay pagos, calcular según fecha último pago
          WHEN ap.fechaUltimoPago <= ex.fechaVto1 THEN 0
          WHEN ap.fechaUltimoPago > ex.fechaVto1
               AND (ex.fechaVto2 IS NULL OR ap.fechaUltimoPago <= ex.fechaVto2)
               THEN ROUND(0.02 * ((ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
                                   - ISNULL(ap.montoPagado, 0)), 2)
          WHEN ex.fechaVto2 IS NOT NULL AND ap.fechaUltimoPago > ex.fechaVto2
               THEN ROUND(0.05 * ((ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
                                   - ISNULL(ap.montoPagado, 0)), 2)
          ELSE 0
      END,
      
      -- Total a pagar = deuda + interés
      ec.totalAPagar = 
          CASE 
              WHEN (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
                   <= ISNULL(ap.montoPagado, 0) 
              THEN 0
              ELSE (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
                   - ISNULL(ap.montoPagado, 0)
          END
          +
          CASE
              WHEN (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
                   <= ISNULL(ap.montoPagado, 0) THEN 0
              WHEN ap.montoPagado IS NULL THEN
                  CASE 
                      WHEN GETDATE() <= ex.fechaVto1 THEN 0
                      WHEN GETDATE() > ex.fechaVto1 
                           AND (ex.fechaVto2 IS NULL OR GETDATE() <= ex.fechaVto2)
                           THEN ROUND(0.02 * (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)), 2)
                      WHEN ex.fechaVto2 IS NOT NULL AND GETDATE() > ex.fechaVto2
                           THEN ROUND(0.05 * (ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)), 2)
                      ELSE 0
                  END
              WHEN ap.fechaUltimoPago <= ex.fechaVto1 THEN 0
              WHEN ap.fechaUltimoPago > ex.fechaVto1
                   AND (ex.fechaVto2 IS NULL OR ap.fechaUltimoPago <= ex.fechaVto2)
                   THEN ROUND(0.02 * ((ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
                                       - ISNULL(ap.montoPagado, 0)), 2)
              WHEN ex.fechaVto2 IS NOT NULL AND ap.fechaUltimoPago > ex.fechaVto2
                   THEN ROUND(0.05 * ((ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) 
                                       - ISNULL(ap.montoPagado, 0)), 2)
              ELSE 0
          END
  FROM app.Tbl_EstadoCuenta ec
  JOIN #FilExp f
    ON f.idConsorcio = ec.idConsorcio
   AND f.nroExpensa  = ec.nroExpensa
  JOIN app.Tbl_Expensa ex
    ON ex.idConsorcio = ec.idConsorcio
   AND ex.nroExpensa  = ec.nroExpensa
  LEFT JOIN AggPagos ap
    ON ap.idEstadoCuenta = ec.idEstadoCuenta;

END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarGastosDesdeExcel
    @RutaArchivo       NVARCHAR(4000),            -- ej: C:\...\datos varios.xlsx
    @Hoja              NVARCHAR(128) = N'Proveedores$', -- hoja de Excel
    @UsarFechaExpensa  DATE = '19000101',         -- fecha de expensa a usar/crear
    @LogPath           NVARCHAR(4000) = NULL,     -- opcional: archivo .log
    @Verbose           BIT = 0                    -- 1 = logs INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarGastosDesdeExcel';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio de proceso', NULL, @RutaArchivo, @LogPath;

        -- 1) Normalizo hoja y proveedor de Excel (HDR=NO porque leemos B3:E...)
        DECLARE @HojaOk NVARCHAR(128) = CASE WHEN RIGHT(ISNULL(@Hoja,N''),1)=N'$' THEN @Hoja ELSE @Hoja + N'$' END;

        IF OBJECT_ID('tempdb..#ExcelCrudo') IS NOT NULL DROP TABLE #ExcelCrudo;
        CREATE TABLE #ExcelCrudo
        (
            tipo_raw        NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- Col B
            descripcion_raw NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- Col C
            proveedor_raw   NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- Col D
            consorcio_raw   NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL   -- Col E (requerido)
        );

        DECLARE @Proveedor NVARCHAR(4000) =
            N'Excel 12.0;HDR=NO;IMEX=1;Database=' + REPLACE(@RutaArchivo, N'''', N'''''');
        DECLARE @Consulta NVARCHAR(4000) =
			N'SELECT * FROM [' + @HojaOk + N']';

        DECLARE @Sql NVARCHAR(MAX) = N'
INSERT INTO #ExcelCrudo(tipo_raw, descripcion_raw, proveedor_raw, consorcio_raw)
SELECT TRY_CAST(F1 AS NVARCHAR(255)),
       TRY_CAST(F2 AS NVARCHAR(255)),
       TRY_CAST(F3 AS NVARCHAR(255)),
       TRY_CAST(F4 AS NVARCHAR(255))
FROM OPENROWSET(''Microsoft.ACE.OLEDB.16.0'',
                ' + QUOTENAME(@Proveedor,'''') + ',
                ' + QUOTENAME(@Consulta, '''') + ');';

        EXEC sys.sp_executesql @Sql;

        IF @Verbose = 1
        BEGIN
            DECLARE @Leidas INT = (SELECT COUNT(*) FROM #ExcelCrudo);
            DECLARE @DetLeidas NVARCHAR(4000) = N'filas=' + CONVERT(NVARCHAR(20), @Leidas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Leídas filas desde Excel', @DetLeidas, @RutaArchivo, @LogPath;
        END

        -- 2) STAGING: tipado básico y mapeo a consorcio
        IF OBJECT_ID('tempdb..#GastosStg') IS NOT NULL DROP TABLE #GastosStg;
        CREATE TABLE #GastosStg
        (
            idConsorcio INT          NOT NULL,
            categoria   VARCHAR(35)  COLLATE DATABASE_DEFAULT NULL,
            descripcion VARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
            proveedor   VARCHAR(100) COLLATE DATABASE_DEFAULT NULL
        );

        INSERT INTO #GastosStg(idConsorcio, categoria, descripcion, proveedor)
        SELECT
            c.idConsorcio,
            importacion.fn_LimpiarTexto(tipo_raw,        35),
            importacion.fn_LimpiarTexto(descripcion_raw, 200),
            importacion.fn_LimpiarTexto(proveedor_raw,   100)
        FROM #ExcelCrudo r
        JOIN app.Tbl_Consorcio c
          ON c.nombre COLLATE DATABASE_DEFAULT =
             importacion.fn_LimpiarTexto(r.consorcio_raw, 50)
        WHERE importacion.fn_LimpiarTexto(r.consorcio_raw, 50) IS NOT NULL;

        -- 3) Expensas: crear las que falten para @UsarFechaExpensa
        IF OBJECT_ID('tempdb..#Expensas') IS NOT NULL DROP TABLE #Expensas;
        CREATE TABLE #Expensas (idConsorcio INT PRIMARY KEY, nroExpensa INT NOT NULL);

        -- existentes
        INSERT INTO #Expensas(idConsorcio, nroExpensa)
        SELECT e.idConsorcio, e.nroExpensa
        FROM app.Tbl_Expensa e
        JOIN (SELECT DISTINCT idConsorcio FROM #GastosStg) d ON d.idConsorcio = e.idConsorcio
        WHERE e.fechaGeneracion = @UsarFechaExpensa;

        -- crear faltantes
        INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
        SELECT DISTINCT s.idConsorcio, @UsarFechaExpensa, NULL, NULL, 0
        FROM #GastosStg s
        WHERE NOT EXISTS (
            SELECT 1 FROM app.Tbl_Expensa e
            WHERE e.idConsorcio = s.idConsorcio AND e.fechaGeneracion = @UsarFechaExpensa
        );

        -- recargar todas a temp
        DELETE FROM #Expensas;
        INSERT INTO #Expensas(idConsorcio, nroExpensa)
        SELECT e.idConsorcio, e.nroExpensa
        FROM app.Tbl_Expensa e
        JOIN (SELECT DISTINCT idConsorcio FROM #GastosStg) d ON d.idConsorcio = e.idConsorcio
        WHERE e.fechaGeneracion = @UsarFechaExpensa;

        -- 4) Insertar Gasto evitando duplicados (por consorcio+expensa+descripcion+proveedor+categoria)
        DECLARE @GastosInsertados INT = 0;

        INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
        SELECT
            x.nroExpensa,
            s.idConsorcio,
            'Ordinario',
            s.descripcion,
            CAST(GETDATE() AS DATE),
            CAST(0 AS DECIMAL(10,2))
        FROM #GastosStg s
        JOIN #Expensas x ON x.idConsorcio = s.idConsorcio
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM app.Tbl_Gasto g
            LEFT JOIN app.Tbl_Gasto_Ordinario go2 ON go2.idGasto = g.idGasto
            WHERE g.idConsorcio = s.idConsorcio
              AND g.nroExpensa  = x.nroExpensa
              AND ISNULL(g.descripcion,'')        COLLATE DATABASE_DEFAULT = ISNULL(s.descripcion,'')
              AND ISNULL(go2.nombreProveedor,'')  COLLATE DATABASE_DEFAULT = ISNULL(s.proveedor,'')
              AND ISNULL(go2.categoria,'')        COLLATE DATABASE_DEFAULT = ISNULL(s.categoria,'')
        );

        SET @GastosInsertados = @@ROWCOUNT;

        -- 5) Crear detalle ordinario para esos gastos (si no existe)
        INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
        SELECT
            g.idGasto,
            s.proveedor,
            s.categoria,
            NULL
        FROM app.Tbl_Gasto g
        JOIN #Expensas x       ON x.nroExpensa = g.nroExpensa AND x.idConsorcio = g.idConsorcio
        JOIN #GastosStg s      ON s.idConsorcio = g.idConsorcio
                              AND ISNULL(g.descripcion,'') COLLATE DATABASE_DEFAULT = ISNULL(s.descripcion,'')
        LEFT JOIN app.Tbl_Gasto_Ordinario go2 ON go2.idGasto = g.idGasto
        WHERE g.tipo = 'Ordinario'
          AND go2.idGasto IS NULL
          AND g.fechaEmision = CAST(GETDATE() AS DATE)
          AND g.importe = 0;

        -- 6) Resumen y logs
        DECLARE @TotalExcel INT = (SELECT COUNT(*) FROM #ExcelCrudo);
        DECLARE @Validas    INT = (SELECT COUNT(*) FROM #GastosStg);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetFin NVARCHAR(4000) =
                N'gastos_insertados=' + CONVERT(NVARCHAR(20), @GastosInsertados) +
                N'; filas_validas=' + CONVERT(NVARCHAR(20), @Validas) +
                N'; filas_excel=' + CONVERT(NVARCHAR(20), @TotalExcel) +
                N'; fecha_expensa=' + CONVERT(NVARCHAR(10), @UsarFechaExpensa, 120);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK', @DetFin, @RutaArchivo, @LogPath;
        END

        /* ==== 6.bis) NUEVO: Recalcular Estado de Cuenta (set-based, sin cursores) ==== */
        DECLARE @fecEC DATE = @UsarFechaExpensa;

        EXEC app.Sp_ActualizarEstadoCuentaDesdeGastos
             @idConsorcio  = NULL,
             @nroExpensa   = NULL,
             @desdeFecha   = @fecEC,
             @hastaFecha   = @fecEC,
             @incluirDummy = 0;

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Recalc EstadoCuenta', N'OK (fecha única)', @RutaArchivo, @LogPath;
        /* ==== FIN agregado ==== */

        SELECT
            filas_excel    = @TotalExcel,
            filas_validas  = @Validas,
            gastos_insert  = @GastosInsertados,
            mensaje        = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @NroError INT            = ERROR_NUMBER();
        DECLARE @Linea    INT            = ERROR_LINE();

        DECLARE @DetError NVARCHAR(4000) =
            N'Falla en importación (' + CONVERT(NVARCHAR(20), @NroError) +
            N' en línea ' + CONVERT(NVARCHAR(20), @Linea) + N')';

        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetError,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;

        ;THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarGastosDesdeJson
    @RutaArchivo NVARCHAR(4000),
    @Anio        INT,
    @DiaVto1     TINYINT = 10,
    @DiaVto2     TINYINT = 20,
    @LogPath     NVARCHAR(4000) = NULL,   -- igual que en otros SPs
    @Verbose     BIT = 1                  -- 1 = loggea INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarGastosDesdeJson';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* 1) Leer JSON completo */
        DECLARE @json NVARCHAR(MAX);
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @sql NVARCHAR(MAX) =
        N'SELECT @jsonOut = BulkColumn
          FROM OPENROWSET (BULK ''' + @RutaEsc + N''', SINGLE_CLOB) AS j;';

        EXEC sp_executesql
             @sql,
             N'@jsonOut NVARCHAR(MAX) OUTPUT',
             @jsonOut = @json OUTPUT;

        IF @json IS NULL
        BEGIN
            DECLARE @DetErrJson NVARCHAR(4000) = N'No se pudo leer el JSON con OPENROWSET.';
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR', N'Lectura JSON', @DetErrJson, @RutaArchivo, @LogPath;
            RAISERROR(N'No se pudo leer el archivo JSON con OPENROWSET. Verificá ruta/permisos y que Ad Hoc Distributed Queries esté habilitado.', 16, 1);
            RETURN;
        END

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'JSON leído', N'OK', @RutaArchivo, @LogPath;

        /* 2) Staging */
        IF OBJECT_ID('tempdb..#stg_gasto') IS NOT NULL DROP TABLE #stg_gasto;
        CREATE TABLE #stg_gasto
        (
            consorcio   NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
            mes_raw     NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
            mes         TINYINT       NULL,
            categoria   NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
            importe_raw NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
            importe     DECIMAL(18,2) NULL
        );

        ;WITH rows AS (
            SELECT CAST([value] AS NVARCHAR(MAX)) AS obj
            FROM OPENJSON(@json)
        ),
        base AS (
            SELECT
                JSON_VALUE(obj, '$."Nombre del consorcio"') AS consorcio,
                JSON_VALUE(obj, '$."Mes"')                  AS mes_raw,
                obj
            FROM rows
        ),
        unpvt AS (
            SELECT 
                b.consorcio,
                b.mes_raw,
                v.categoria,
                v.importe_raw
            FROM base b
            CROSS APPLY ( VALUES
                (N'BANCARIOS',               JSON_VALUE(b.obj, '$."BANCARIOS"')),
                (N'LIMPIEZA',                JSON_VALUE(b.obj, '$."LIMPIEZA"')),
                (N'ADMINISTRACION',          JSON_VALUE(b.obj, '$."ADMINISTRACION"')),
                (N'SEGUROS',                 JSON_VALUE(b.obj, '$."SEGUROS"')),
                (N'GASTOS GENERALES',        JSON_VALUE(b.obj, '$."GASTOS GENERALES"')),
                (N'SERVICIOS PUBLICOS-Agua', JSON_VALUE(b.obj, '$."SERVICIOS PUBLICOS-Agua"')),
                (N'SERVICIOS PUBLICOS-Luz',  JSON_VALUE(b.obj, '$."SERVICIOS PUBLICOS-Luz"'))
            ) AS v(categoria, importe_raw)
        )
        INSERT INTO #stg_gasto (consorcio, mes_raw, categoria, importe_raw, mes, importe)
        SELECT
            LTRIM(RTRIM(consorcio))         COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(mes_raw))           COLLATE DATABASE_DEFAULT,
            v.categoria                     COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(importe_raw))       COLLATE DATABASE_DEFAULT,
            CASE 
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'enero')      THEN 1
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'febrero')    THEN 2
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'marzo')      THEN 3
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'abril')      THEN 4
                WHEN LOWER(REPLACE(mes_raw,' ','')) LIKE N'mayo%'    THEN 5
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'junio')      THEN 6
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'julio')      THEN 7
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'agosto')     THEN 8
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'septiembre') THEN 9
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'octubre')    THEN 10
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'noviembre')  THEN 11
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'diciembre')  THEN 12
            END,
            CASE 
                WHEN importe_raw IS NULL OR importe_raw = N'' THEN NULL
                ELSE importacion.fn_ParseImporteFlexible(importe_raw)
            END
        FROM unpvt v
        WHERE NULLIF(LTRIM(RTRIM(consorcio)), N'') IS NOT NULL;

        DECLARE @Stg INT = (SELECT COUNT(*) FROM #stg_gasto);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetStg NVARCHAR(4000) = N'filas_stg=' + CONVERT(NVARCHAR(20), @Stg);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'STG cargado', @DetStg, @RutaArchivo, @LogPath;
        END

        IF EXISTS (SELECT 1 FROM #stg_gasto WHERE importe_raw IS NOT NULL AND importe IS NULL)
            EXEC reportes.Sp_LogReporte @Procedimiento, 'WARN', N'Importes no convertidos', N'Hay importes con NULL tras parseo', @RutaArchivo, @LogPath;

        /* 3) Mapa de extraordinarios (editable) */
        IF OBJECT_ID('tempdb..#map_extra') IS NOT NULL DROP TABLE #map_extra;
        CREATE TABLE #map_extra (categoria NVARCHAR(100) COLLATE DATABASE_DEFAULT PRIMARY KEY);

        /* 4) Consorcios: crear los faltantes */
        ;WITH cte_cons AS (
            SELECT DISTINCT consorcio
            FROM #stg_gasto
            WHERE consorcio IS NOT NULL AND consorcio <> N''
        )
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT c.consorcio, NULL, NULL
        FROM cte_cons c
        LEFT JOIN app.Tbl_Consorcio tc
               ON tc.nombre = c.consorcio COLLATE DATABASE_DEFAULT
        WHERE tc.idConsorcio IS NULL;

        DECLARE @ConsCreados INT = @@ROWCOUNT;
        IF @Verbose = 1
        BEGIN
            DECLARE @DetCons NVARCHAR(4000) = N'consorcios_creados=' + CONVERT(NVARCHAR(20), @ConsCreados);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Consorcios creados', @DetCons, @RutaArchivo, @LogPath;
        END

        IF OBJECT_ID('tempdb..#cons') IS NOT NULL DROP TABLE #cons;
        SELECT c.consorcio, tc.idConsorcio
        INTO #cons
        FROM (SELECT DISTINCT consorcio FROM #stg_gasto) c
        INNER JOIN app.Tbl_Consorcio tc
                ON tc.nombre = c.consorcio COLLATE DATABASE_DEFAULT;

        /* 5) Totales por Consorcio+Mes */
        IF OBJECT_ID('tempdb..#exp_sum') IS NOT NULL DROP TABLE #exp_sum;
        SELECT cn.idConsorcio, s.mes, SUM(s.importe) AS total
        INTO #exp_sum
        FROM #stg_gasto s
        INNER JOIN #cons cn ON cn.consorcio = s.consorcio COLLATE DATABASE_DEFAULT
        WHERE s.importe IS NOT NULL AND s.mes BETWEEN 1 AND 12
        GROUP BY cn.idConsorcio, s.mes;

        DECLARE @RowsSum INT = (SELECT COUNT(*) FROM #exp_sum);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetSum NVARCHAR(4000) = N'grupos_consorcio_mes=' + CONVERT(NVARCHAR(20), @RowsSum);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Totales por mes', @DetSum, @RutaArchivo, @LogPath;
        END

        /* 6) Crear/Actualizar Expensas (SET-BASED, sin cursor, con clamp a DEC(10,2)) */
        IF OBJECT_ID('tempdb..#exp') IS NOT NULL DROP TABLE #exp;
        IF OBJECT_ID('tempdb..#merge_out') IS NOT NULL DROP TABLE #merge_out;
        CREATE TABLE #merge_out(accion NVARCHAR(10));

        ;WITH calc AS (
            -- Partimos de #exp_sum (idConsorcio, mes, total)
            SELECT
                es.idConsorcio,
                es.mes,
                es.total,
                -- 5° día hábil del mes
                fechaGeneracion =
                (
                    SELECT MAX(d)
                    FROM (
                        SELECT TOP (5)
                               DATEADD(DAY, v.n, DATEFROMPARTS(@Anio, es.mes, 1)) AS d
                        FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13)) v(n)
                        WHERE DATENAME(WEEKDAY,
                                       DATEADD(DAY, v.n, DATEFROMPARTS(@Anio, es.mes, 1))) NOT IN ('Saturday', 'Sunday')
                        ORDER BY d
                    ) q
                ),
                finMes = EOMONTH(DATEFROMPARTS(@Anio, es.mes, 1))
            FROM #exp_sum es
        ),
        src AS (
            SELECT
                c.idConsorcio,
                c.mes,
                c.fechaGeneracion,
                vto1 = CASE 
                         WHEN @DiaVto1 IS NULL THEN c.finMes
                         ELSE DATEFROMPARTS(YEAR(c.fechaGeneracion), MONTH(c.fechaGeneracion),
                                            IIF(@DiaVto1 > DAY(c.finMes), DAY(c.finMes), @DiaVto1))
                       END,
                vto2 = CASE 
                         WHEN @DiaVto2 IS NULL THEN c.finMes
                         ELSE DATEFROMPARTS(YEAR(c.fechaGeneracion), MONTH(c.fechaGeneracion),
                                            IIF(@DiaVto2 > DAY(c.finMes), DAY(c.finMes), @DiaVto2))
                       END,
                -- clamp a DEC(10,2) para respetar Tbl_Expensa.montoTotal
                montoTotal = CAST(CASE 
                                    WHEN c.total >  99999999.99 THEN  99999999.99
                                    WHEN c.total < -99999999.99 THEN -99999999.99
                                    ELSE c.total
                                  END AS DECIMAL(10,2))
            FROM calc c
        )
        MERGE app.Tbl_Expensa AS T
        USING src AS S
           ON T.idConsorcio     = S.idConsorcio
          AND T.fechaGeneracion = S.fechaGeneracion
        WHEN MATCHED THEN
            UPDATE SET T.fechaVto1  = S.vto1,
                       T.fechaVto2  = S.vto2,
                       T.montoTotal = S.montoTotal
        WHEN NOT MATCHED THEN
            INSERT (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
            VALUES (S.idConsorcio, S.fechaGeneracion, S.vto1, S.vto2, S.montoTotal)
        OUTPUT $action INTO #merge_out;

        -- métricas de expensas
        DECLARE @ExpensasCreadas INT      = (SELECT COUNT(*) FROM #merge_out WHERE accion = 'INSERT');
        DECLARE @ExpensasActualizadas INT = (SELECT COUNT(*) FROM #merge_out WHERE accion = 'UPDATE');

        -- reconstruimos #exp (idConsorcio, mes, nroExpensa) por año+mes
        SELECT s.idConsorcio,
               s.mes,
               e.nroExpensa
        INTO #exp
        FROM #exp_sum s
        JOIN app.Tbl_Expensa e
          ON e.idConsorcio = s.idConsorcio
         AND YEAR(e.fechaGeneracion)  = @Anio
         AND MONTH(e.fechaGeneracion) = s.mes;

        IF @Verbose = 1
        BEGIN
            DECLARE @DetExp NVARCHAR(4000) =
                N'expensas_creadas=' + CONVERT(NVARCHAR(20), @ExpensasCreadas) +
                N'; expensas_actualizadas=' + CONVERT(NVARCHAR(20), @ExpensasActualizadas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Expensas procesadas', @DetExp, @RutaArchivo, @LogPath;
        END

        /* 7) Insertar Gastos + capturar categorías (importe clamped a DEC(10,2)) */
        IF OBJECT_ID('tempdb..#ins') IS NOT NULL DROP TABLE #ins;
        CREATE TABLE #ins
        (
            idGasto   INT NOT NULL,
            categoria NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL
        );

        MERGE app.Tbl_Gasto AS tgt
        USING (
            SELECT 
                e.nroExpensa                                                    AS nroExpensa,
                c.idConsorcio                                                   AS idConsorcio,
                /* tipar + collation para evitar conflictos */
                CAST(CASE WHEN mx.categoria IS NOT NULL 
                          THEN 'Extraordinario' ELSE 'Ordinario' END AS VARCHAR(16)) COLLATE DATABASE_DEFAULT AS tipo,
                s.categoria                                                     AS descripcion,   -- literal desde JSON
                DATEFROMPARTS(@Anio, s.mes, 1)                                  AS fechaEmision,
                /* clamp + cast para respetar DEC(10,2) de Tbl_Gasto.importe */
                CAST(CASE 
                        WHEN s.importe >  99999999.99 THEN  99999999.99
                        WHEN s.importe < -99999999.99 THEN -99999999.99
                        ELSE s.importe
                    END AS DECIMAL(10,2))                                       AS importe,
                s.categoria                                                     AS categoria
            FROM #stg_gasto s
            INNER JOIN #cons c  ON c.consorcio = s.consorcio COLLATE DATABASE_DEFAULT
            INNER JOIN #exp e   ON e.idConsorcio = c.idConsorcio AND e.mes = s.mes
            LEFT  JOIN #map_extra mx ON mx.categoria = s.categoria COLLATE DATABASE_DEFAULT
            WHERE s.importe IS NOT NULL AND s.mes BETWEEN 1 AND 12
        ) AS src
        ON  tgt.idConsorcio = src.idConsorcio
        AND tgt.nroExpensa  = src.nroExpensa
        AND tgt.tipo        = src.tipo
        AND ISNULL(tgt.descripcion,'') = ISNULL(src.descripcion,'')
        WHEN NOT MATCHED THEN
            INSERT (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
            VALUES (src.nroExpensa, src.idConsorcio, src.tipo, src.descripcion, src.fechaEmision, src.importe)
        OUTPUT INSERTED.idGasto, src.categoria INTO #ins(idGasto, categoria);

        DECLARE @GastosInsertados INT = (SELECT COUNT(*) FROM #ins);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetG NVARCHAR(4000) = N'gastos_insertados=' + CONVERT(NVARCHAR(20), @GastosInsertados);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Gastos insertados', @DetG, @RutaArchivo, @LogPath;
        END

        /* 8) Subtablas */
        INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
        SELECT i.idGasto, NULL, i.categoria, NULL
        FROM #ins i
        LEFT JOIN #map_extra mx ON mx.categoria = i.categoria COLLATE DATABASE_DEFAULT
        WHERE mx.categoria IS NULL;

        DECLARE @OrdIns INT = @@ROWCOUNT;

        INSERT INTO app.Tbl_Gasto_Extraordinario (idGasto, cuotaActual, cantCuotas)
        SELECT i.idGasto, 1, 1
        FROM #ins i
        INNER JOIN #map_extra mx ON mx.categoria = i.categoria COLLATE DATABASE_DEFAULT;

        DECLARE @ExtIns INT = @@ROWCOUNT;

        IF @Verbose = 1
        BEGIN
            DECLARE @DetSub NVARCHAR(4000) =
                N'ordinarios=' + CONVERT(NVARCHAR(20), @OrdIns) +
                N'; extraordinarios=' + CONVERT(NVARCHAR(20), @ExtIns);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Subtablas cargadas', @DetSub, @RutaArchivo, @LogPath;
        END

        /* ==== 8.bis) NUEVO: Recalcular Estado de Cuenta (set-based, sin cursores) ==== */
        DECLARE @fecDesde DATE = DATEFROMPARTS(@Anio, 1, 1);
        DECLARE @fecHasta DATE = DATEFROMPARTS(@Anio, 12, 31);

        EXEC app.Sp_ActualizarEstadoCuentaDesdeGastos
             @idConsorcio  = NULL,
             @nroExpensa   = NULL,
             @desdeFecha   = @fecDesde,
             @hastaFecha   = @fecHasta,
             @incluirDummy = 0;

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Recalc EstadoCuenta', N'OK (rango anual)', @RutaArchivo, @LogPath;
        /* ==== FIN agregado ==== */

        /* 9) Fin + resumen */
        DECLARE @Resumen NVARCHAR(4000) =
            N'stg=' + CONVERT(NVARCHAR(20), @Stg) +
            N'; cons_creados=' + CONVERT(NVARCHAR(20), @ConsCreados) +
            N'; exp_creadas=' + CONVERT(NVARCHAR(20), @ExpensasCreadas) +
            N'; exp_actualizadas=' + CONVERT(NVARCHAR(20), @ExpensasActualizadas) +
            N'; gastos=' + CONVERT(NVARCHAR(20), @GastosInsertados) +
            N'; ord=' + CONVERT(NVARCHAR(20), @OrdIns) +
            N'; ext=' + CONVERT(NVARCHAR(20), @ExtIns);

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK', @Resumen, @RutaArchivo, @LogPath;

        SELECT
            filas_stg                  = @Stg,
            consorcios_creados         = @ConsCreados,
            expensas_creadas           = @ExpensasCreadas,
            expensas_actualizadas      = @ExpensasActualizadas,
            gastos_insertados          = @GastosInsertados,
            ordinarios_insertados      = @OrdIns,
            extraordinarios_insertados = @ExtIns,
            mensaje                    = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) = N'Error en línea ' + CONVERT(NVARCHAR(10), ERROR_LINE());
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarConsorcioYUF_DesdeCsv
    @RutaArchivo NVARCHAR(4000),            -- C:\...\Inquilino-propietarios-UF.csv
    @HDR         BIT = 1,                   -- 1 = primera fila encabezado
    @LogPath     NVARCHAR(4000) = NULL,     -- opcional: archivo .log
    @Verbose     BIT = 0                    -- 1 = logs INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarConsorcioYUF_DesdeCsv';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* 1) Leer CSV (UTF-8, separador |) a tabla temporal */
        IF OBJECT_ID('tempdb..#CsvCrudo','U') IS NOT NULL DROP TABLE #CsvCrudo;
        CREATE TABLE #CsvCrudo
        (
            [CVU/CBU]              NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [Nombre del consorcio] NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [nroUnidadFuncional]   NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [piso]                 NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [departamento]         NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        DECLARE @PrimeraFila INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');
        DECLARE @PrimeraFilaTxt NVARCHAR(10) = CONVERT(NVARCHAR(10), @PrimeraFila);

        DECLARE @SqlBulk NVARCHAR(MAX);
        SET @SqlBulk =
              N'BULK INSERT #CsvCrudo '
            + N'FROM ''' + @RutaEsc + N''' '
            + N'WITH ( '
            + N' FIRSTROW = ' + @PrimeraFilaTxt
            + N',FIELDTERMINATOR = ''|'''
            + N',ROWTERMINATOR   = ''0x0d0a'''
            + N',CODEPAGE        = ''65001'''
            + N',KEEPNULLS, TABLOCK );';
        EXEC (@SqlBulk);

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasCsv INT = (SELECT COUNT(*) FROM #CsvCrudo);
            DECLARE @DetLeidas NVARCHAR(4000) = N'filas_csv=' + CONVERT(NVARCHAR(20), @FilasCsv);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Archivo leído', @DetLeidas, @RutaArchivo, @LogPath;
        END

        /* 2) STAGING (normalizo texto y CBU; PB => 0) */
        IF OBJECT_ID('tempdb..#UF_Stg','U') IS NOT NULL DROP TABLE #UF_Stg;
        CREATE TABLE #UF_Stg
        (
            idUnidadFuncional INT         NULL,  -- puede venir vacío, no lo forzamos
            nombre            VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL,
            piso              TINYINT     NULL,
            departamento      CHAR(1)     COLLATE DATABASE_DEFAULT NULL,
            cbu_cvu_norm      CHAR(22)    COLLATE DATABASE_DEFAULT NULL
        );

        INSERT INTO #UF_Stg (idUnidadFuncional, nombre, piso, departamento, cbu_cvu_norm)
        SELECT
            TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM([nroUnidadFuncional])), '')),
            importacion.fn_LimpiarTexto([Nombre del consorcio], 50),
            CASE
                WHEN UPPER(LTRIM(RTRIM([piso]))) IN (N'PB', N'P.B', N'P.B.', N'PLANTA BAJA') THEN 0
                ELSE TRY_CONVERT(TINYINT, NULLIF(LTRIM(RTRIM([piso])), ''))
            END,
            CASE
                WHEN NULLIF(LTRIM(RTRIM([departamento])), '') IS NULL THEN NULL
                ELSE SUBSTRING(LTRIM(RTRIM([departamento])), 1, 1)
            END,
            CASE
                WHEN LEN(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                         LTRIM(RTRIM([CVU/CBU])),' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                         '(' ,''),')',''),CHAR(9),''),CHAR(160),'')) = 22
                 AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                         LTRIM(RTRIM([CVU/CBU])),' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                         '(' ,''),')',''),CHAR(9),''),CHAR(160),'') NOT LIKE '%[^0-9]%'
                THEN CONVERT(CHAR(22),
                     REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                     LTRIM(RTRIM([CVU/CBU])),' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                     '(' ,''),')',''),CHAR(9),''),CHAR(160),'')) 
                ELSE NULL
            END
        FROM #CsvCrudo
        WHERE importacion.fn_LimpiarTexto([Nombre del consorcio], 50) IS NOT NULL;

        /* 3) DEDUP simple */
        IF OBJECT_ID('tempdb..#UF_Dedup','U') IS NOT NULL DROP TABLE #UF_Dedup;
        SELECT DISTINCT idUnidadFuncional, nombre, piso, departamento, cbu_cvu_norm
        INTO #UF_Dedup
        FROM #UF_Stg;

        /* 4) Asegurar consorcios */
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT d.nombre, NULL, NULL
        FROM (SELECT DISTINCT nombre FROM #UF_Dedup) d
        WHERE NOT EXISTS (
            SELECT 1 FROM app.Tbl_Consorcio c 
            WHERE c.nombre COLLATE DATABASE_DEFAULT = d.nombre
        );

        /* 5) ACTUALIZAR UFs existentes
              a) por idUnidadFuncional si vino en el archivo
              b) si NO vino id, por match lógico (consorcio + piso + departamento)
              Siempre cuidando CBU_CVU UNIQUE
        */

-- a) update por id (idempotente)
        UPDATE u
           SET u.piso         = d.piso,
               u.departamento = d.departamento,
               u.CBU_CVU      = d.cbu_cvu_norm
        FROM app.Tbl_UnidadFuncional u
        JOIN #UF_Dedup d
          ON d.idUnidadFuncional IS NOT NULL
         AND d.idUnidadFuncional = u.idUnidadFuncional
        -- (opcional pero más preciso: asegura que la UF pertenece a ese consorcio)
        JOIN app.Tbl_Consorcio c
          ON c.idConsorcio = u.idConsorcio
         AND c.nombre COLLATE DATABASE_DEFAULT = d.nombre COLLATE DATABASE_DEFAULT
        WHERE
            -- cambia piso o departamento
            ISNULL(u.piso,255) <> ISNULL(d.piso,255)
         OR ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT
            <> ISNULL(d.departamento,'') COLLATE DATABASE_DEFAULT
         OR (
              -- cambia CBU y no rompe la unicidad
              d.cbu_cvu_norm IS NOT NULL
          AND ISNULL(u.CBU_CVU,'') <> d.cbu_cvu_norm
          AND NOT EXISTS (
                SELECT 1
                FROM app.Tbl_UnidadFuncional x
                WHERE x.CBU_CVU = d.cbu_cvu_norm
                  AND x.idUnidadFuncional <> u.idUnidadFuncional
          )
         );
        DECLARE @upd_por_id INT = @@ROWCOUNT;

        -- b) update por (consorcio+piso+depto) cuando NO vino id
        UPDATE u
           SET u.CBU_CVU = CASE
                               WHEN d.cbu_cvu_norm IS NULL THEN u.CBU_CVU
                               WHEN u.CBU_CVU = d.cbu_cvu_norm THEN u.CBU_CVU
                               WHEN NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional x 
                                                WHERE x.CBU_CVU = d.cbu_cvu_norm
                                                  AND x.idUnidadFuncional <> u.idUnidadFuncional)
                               THEN d.cbu_cvu_norm
                               ELSE u.CBU_CVU
                           END
        FROM app.Tbl_UnidadFuncional u
        JOIN app.Tbl_Consorcio c ON c.idConsorcio = u.idConsorcio
        JOIN #UF_Dedup d
          ON d.idUnidadFuncional IS NULL
         AND c.nombre COLLATE DATABASE_DEFAULT = d.nombre COLLATE DATABASE_DEFAULT
         AND ISNULL(u.piso,255) = ISNULL(d.piso,255)
         AND ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT = ISNULL(d.departamento,'') COLLATE DATABASE_DEFAULT;

        DECLARE @upd_por_match INT = @@ROWCOUNT;

        DECLARE @UFsActualizadas INT = @upd_por_id + @upd_por_match;

        /* 6) INSERTAR UFs nuevas SIN IDENTITY_INSERT
              Criterio: que NO exista ni por id (si vino) ni por match lógico
        */
        INSERT INTO app.Tbl_UnidadFuncional
            (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje, CBU_CVU)
        SELECT
            c.idConsorcio,
            d.piso,
            d.departamento,
            NULL, NULL, NULL, NULL,
            d.cbu_cvu_norm
        FROM #UF_Dedup d
        JOIN app.Tbl_Consorcio c 
          ON c.nombre COLLATE DATABASE_DEFAULT = d.nombre COLLATE DATABASE_DEFAULT
        WHERE
            -- no existe por id (cuando vino id)
            NOT EXISTS (
                SELECT 1 FROM app.Tbl_UnidadFuncional u
                WHERE d.idUnidadFuncional IS NOT NULL
                  AND u.idUnidadFuncional = d.idUnidadFuncional
            )
            -- y no existe por match lógico
            AND NOT EXISTS (
                SELECT 1 FROM app.Tbl_UnidadFuncional u
                WHERE u.idConsorcio = c.idConsorcio
                  AND ISNULL(u.piso,255) = ISNULL(d.piso,255)
                  AND ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT =
                      ISNULL(d.departamento,'') COLLATE DATABASE_DEFAULT
            )
            -- y CBU_CVU libre (si viene)
            AND (
                 d.cbu_cvu_norm IS NULL
              OR NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional u2 WHERE u2.CBU_CVU = d.cbu_cvu_norm)
            );

        DECLARE @UFsInsertadas INT = @@ROWCOUNT;

        /* 7) Resumen + log */
        DECLARE @TotalCsv INT = (SELECT COUNT(*) FROM #CsvCrudo);
        DECLARE @FilasStg INT = (SELECT COUNT(*) FROM #UF_Stg);
        DECLARE @FilasDed INT = (SELECT COUNT(*) FROM #UF_Dedup);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetalleFin NVARCHAR(4000);
            SET @DetalleFin = N'csv=' + CONVERT(NVARCHAR(20), @TotalCsv)
                            + N'; staging=' + CONVERT(NVARCHAR(20), @FilasStg)
                            + N'; dedup=' + CONVERT(NVARCHAR(20), @FilasDed)
                            + N'; ufs_upd=' + CONVERT(NVARCHAR(20), @UFsActualizadas)
                            + N'; ufs_ins=' + CONVERT(NVARCHAR(20), @UFsInsertadas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK', @DetalleFin, @RutaArchivo, @LogPath;
        END

        SELECT
            total_csv        = @TotalCsv,
            procesadas_stg   = @FilasStg,
            sin_duplicados   = @FilasDed,
            ufs_actualizadas = @UFsActualizadas,
            ufs_insertadas   = @UFsInsertadas,
            mensaje          = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) = N'Error en línea ' + CONVERT(NVARCHAR(10), ERROR_LINE());
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarUFsDesdeTxt
    @RutaArchivo    NVARCHAR(4000),
    @HDR            BIT = 1,
    @RowTerminator  NVARCHAR(10) = N'0x0d0a',
    @CodePage       NVARCHAR(16) = N'65001',
    @LogPath        NVARCHAR(4000) = NULL,
    @Verbose        BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarUFsDesdeTxt';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* 1) RAW (lectura TXT con tabuladores) */
        IF OBJECT_ID('tempdb..#RawUF','U') IS NOT NULL DROP TABLE #RawUF;
        CREATE TABLE #RawUF
        (
            [Nombre del consorcio] NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [nroUnidadFuncional]   NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [Piso]                 NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [departamento]         NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [coeficiente]          NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [m2_unidad_funcional]  NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [bauleras]             NVARCHAR(10)  COLLATE DATABASE_DEFAULT NULL,
            [cochera]              NVARCHAR(10)  COLLATE DATABASE_DEFAULT NULL,
            [m2_baulera]           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [m2_cochera]           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        DECLARE @PrimeraFila INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @SqlBulk NVARCHAR(MAX) =
            N'BULK INSERT #RawUF FROM ''' + @RutaEsc + N''' ' +
            N'WITH ( FIRSTROW=' + CONVERT(NVARCHAR(10), @PrimeraFila) +
            N', FIELDTERMINATOR=''0x09''' +          -- TAB
            N', ROWTERMINATOR=''' + @RowTerminator + N'''' +
            N', CODEPAGE='''      + @CodePage      + N'''' +
            N', KEEPNULLS, TABLOCK );';
        EXEC (@SqlBulk);

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasTxt INT = (SELECT COUNT(*) FROM #RawUF);
            DECLARE @Det1 NVARCHAR(4000) = N'filas_txt=' + CONVERT(NVARCHAR(20), @FilasTxt);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Archivo TXT leído',
                 @Det1, @RutaArchivo, @LogPath;
        END

        /* 2) STAGING normalizado (una fila por registro del TXT) */
        IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            nombre           VARCHAR(50)   COLLATE DATABASE_DEFAULT NOT NULL,
            piso             TINYINT       NULL,
            departamento     CHAR(1)       COLLATE DATABASE_DEFAULT NULL,
            porcentaje       DECIMAL(5,2)  NULL,
            superficie       DECIMAL(7,2)  NULL,
            metrosBaulera    DECIMAL(5,2)  NULL,
            metrosCochera    DECIMAL(5,2)  NULL
        );

        INSERT INTO #Stg (nombre, piso, departamento, porcentaje, superficie, metrosBaulera, metrosCochera)
        SELECT
            importacion.fn_LimpiarTexto([Nombre del consorcio], 50),
            CASE WHEN UPPER(LTRIM(RTRIM([Piso]))) IN (N'PB',N'P.B',N'P.B.',N'PLANTA BAJA') THEN 0
                 ELSE TRY_CONVERT(TINYINT, NULLIF(LTRIM(RTRIM([Piso])),'')) END,
            CASE WHEN NULLIF(LTRIM(RTRIM([departamento])), '') IS NULL THEN NULL
                 ELSE SUBSTRING(LTRIM(RTRIM([departamento])), 1, 1) END,
            importacion.fn_A_Decimal([coeficiente]),
            importacion.fn_A_Decimal([m2_unidad_funcional]),
            importacion.fn_A_Decimal([m2_baulera]),
            importacion.fn_A_Decimal([m2_cochera])
        FROM #RawUF
        WHERE importacion.fn_LimpiarTexto([Nombre del consorcio], 50) IS NOT NULL;

        /* 2.b) Consolidación por clave (nombre+piso+depto) para evitar picks no deterministas */
        IF OBJECT_ID('tempdb..#StgKey','U') IS NOT NULL DROP TABLE #StgKey;
        ;WITH g AS (
          SELECT
            nombre, piso, departamento,
            MAX(porcentaje)    AS porcentaje,       -- conserva no-nulos
            MAX(superficie)    AS superficie,
            MAX(metrosBaulera) AS metrosBaulera,
            MAX(metrosCochera) AS metrosCochera
          FROM #Stg
          GROUP BY nombre, piso, departamento
        )
        SELECT nombre, piso, departamento, porcentaje, superficie, metrosBaulera, metrosCochera
        INTO #StgKey
        FROM g;

        /* 3) Asegurar Consorcios (comparando nombre normalizado vs normalizado) */
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT DISTINCT k.nombre, NULL, NULL
        FROM #StgKey k
        WHERE NOT EXISTS (
          SELECT 1
          FROM app.Tbl_Consorcio c
          WHERE importacion.fn_LimpiarTexto(c.nombre, 50) = k.nombre
        );

        /* 3.b) Mapa (idConsorcio, nombre_normalizado) para joins estables */
        IF OBJECT_ID('tempdb..#ConsorcioMap','U') IS NOT NULL DROP TABLE #ConsorcioMap;
        SELECT
          c.idConsorcio,
          nom_norm = importacion.fn_LimpiarTexto(c.nombre, 50)
        INTO #ConsorcioMap
        FROM app.Tbl_Consorcio c;

        /* 4) UPDATE UFs existentes (idempotente / no pisa con NULL) */
        UPDATE u
           SET u.superficie    = k.superficie,
               u.metrosBaulera = k.metrosBaulera,
               u.metrosCochera = k.metrosCochera,
               u.porcentaje    = k.porcentaje
        FROM app.Tbl_UnidadFuncional u
        JOIN #ConsorcioMap cm
          ON cm.idConsorcio = u.idConsorcio
        JOIN #StgKey k
          ON k.nombre COLLATE DATABASE_DEFAULT = cm.nom_norm COLLATE DATABASE_DEFAULT
         AND ISNULL(u.piso,255) = ISNULL(k.piso,255)
         AND ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT
             = ISNULL(k.departamento,'') COLLATE DATABASE_DEFAULT
        WHERE
           (k.superficie    IS NOT NULL AND ISNULL(u.superficie    , -0.01) <> k.superficie)
        OR (k.metrosBaulera IS NOT NULL AND ISNULL(u.metrosBaulera , -0.01) <> k.metrosBaulera)
        OR (k.metrosCochera IS NOT NULL AND ISNULL(u.metrosCochera , -0.01) <> k.metrosCochera)
        OR (k.porcentaje    IS NOT NULL AND ISNULL(u.porcentaje    , -0.01) <> k.porcentaje);

        DECLARE @UFsActualizadas INT = @@ROWCOUNT;

        /* 5) INSERT UFs nuevas (una por clave) usando el mismo mapa */
        INSERT INTO app.Tbl_UnidadFuncional
          (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje)
        SELECT
          cm.idConsorcio, k.piso, k.departamento,
          k.superficie, k.metrosBaulera, k.metrosCochera, k.porcentaje
        FROM #StgKey k
        JOIN #ConsorcioMap cm
          ON cm.nom_norm COLLATE DATABASE_DEFAULT = k.nombre COLLATE DATABASE_DEFAULT
        WHERE NOT EXISTS (
          SELECT 1
          FROM app.Tbl_UnidadFuncional u
          WHERE u.idConsorcio = cm.idConsorcio
            AND ISNULL(u.piso,255) = ISNULL(k.piso,255)
            AND ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT
                = ISNULL(k.departamento,'') COLLATE DATABASE_DEFAULT
        );

        DECLARE @UFsInsertadas INT = @@ROWCOUNT;

        /* 6) Resumen + log */
        DECLARE @TotTxt INT = (SELECT COUNT(*) FROM #RawUF);
        DECLARE @TotStg INT = (SELECT COUNT(*) FROM #Stg);
        DECLARE @TotKey INT = (SELECT COUNT(*) FROM #StgKey);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetFin NVARCHAR(4000) =
                N'txt=' + CONVERT(NVARCHAR(20), @TotTxt) +
                N'; stg=' + CONVERT(NVARCHAR(20), @TotStg) +
                N'; stgkey=' + CONVERT(NVARCHAR(20), @TotKey) +
                N'; ufs_upd=' + CONVERT(NVARCHAR(20), @UFsActualizadas) +
                N'; ufs_ins=' + CONVERT(NVARCHAR(20), @UFsInsertadas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK',
                 @DetFin, @RutaArchivo, @LogPath;
        END

        SELECT
            filas_txt        = @TotTxt,
            filas_validas    = @TotStg,
            claves_unicas    = @TotKey,
            ufs_actualizadas = @UFsActualizadas,
            ufs_insertadas   = @UFsInsertadas,
            mensaje          = N'OK: consolidado por clave; joins por nombre normalizado; sin sobrescribir con NULL';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) = N'Error en línea ' + CONVERT(NVARCHAR(10), ERROR_LINE());
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarUFInquilinosDesdeCsv
    @RutaArchivo    NVARCHAR(4000),            -- C:\...\Inquilino-propietarios-datos.csv
    @HDR            BIT = 1,                   -- 1 = primera fila encabezado
    @RowTerminator  NVARCHAR(10) = N'0x0d0a',  -- CRLF (usar '0x0a' si solo LF)
    @CodePage       NVARCHAR(16) = N'ACP',     -- Latin-1; usar '65001' si UTF-8
    @LogPath        NVARCHAR(4000) = NULL,     -- opcional: archivo .log
    @Verbose        BIT = 0                    -- 1 = logs INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarUFInquilinosDesdeCsv';

    BEGIN TRY
        /* 0) Log inicio */
        IF @Verbose = 1
        BEGIN
            DECLARE @Det0 NVARCHAR(4000) = NULL;
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'Inicio del proceso',
                 @Detalle       = @Det0,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END;

        /* 1) RAW del CSV (';') */
        IF OBJECT_ID('tempdb..#Raw','U') IS NOT NULL DROP TABLE #Raw;
        CREATE TABLE #Raw
        (
            [Nombre]                 NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [apellido]               NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [DNI]                    NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [email personal]         NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [telfono de contacto]   NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL, -- viene así
            [CVU/CBU]                NVARCHAR(64)  COLLATE DATABASE_DEFAULT NULL,
            [Inquilino]              NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        DECLARE @PrimeraFila INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;
        DECLARE @PrimeraFilaTxt NVARCHAR(10) = CONVERT(NVARCHAR(10), @PrimeraFila);
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @SqlBulk NVARCHAR(MAX);
        SET @SqlBulk = CONCAT(
            N'BULK INSERT #Raw FROM ''', @RutaEsc, N''' WITH ( ',
            N'FIRSTROW = ', @PrimeraFilaTxt,
            N', FIELDTERMINATOR = '';''',
            N', ROWTERMINATOR  = ''', @RowTerminator, N'''',
            N', CODEPAGE       = ''', @CodePage, N'''',
            N', KEEPNULLS, TABLOCK );'
        );

        EXEC (@SqlBulk);

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasRaw INT = (SELECT COUNT(*) FROM #Raw);
            DECLARE @Det1 NVARCHAR(4000) = CONCAT(N'filas_csv=', CONVERT(NVARCHAR(20), @FilasRaw));
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'CSV leído',
                 @Detalle       = @Det1,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END;

        /* 2) STAGING: normalizar CBU/CVU (22 dígitos) y mapear inquilino / propietario */
        IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            cbu_cvu     CHAR(22)     COLLATE DATABASE_DEFAULT NOT NULL,
            esInquilino BIT          NOT NULL,
            dni         INT          NULL,
            nombre      VARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
            apellido    VARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
            email       VARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            telefono    VARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        ;WITH s AS
        (
            SELECT
                cbu_raw = LTRIM(RTRIM([CVU/CBU])),
                inq_raw = LTRIM(RTRIM([Inquilino])),
                dni_raw = LTRIM(RTRIM([DNI])),
                nom_raw = LTRIM(RTRIM([Nombre])),
                ape_raw = LTRIM(RTRIM([apellido])),
                mail_raw= LTRIM(RTRIM([email personal])),
                tel_raw = LTRIM(RTRIM([telfono de contacto]))
            FROM #Raw
        ),
        n AS
        (
            SELECT
                cbu_norm =
                    REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                        s.cbu_raw,' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                        '(' ,''),')',''),CHAR(9),''),CHAR(160),''),

                inq_norm = LOWER(s.inq_raw),
                dni_norm = TRY_CONVERT(INT, NULLIF(s.dni_raw,'')),
                nom_norm = NULLIF(s.nom_raw,''),
                ape_norm = NULLIF(s.ape_raw,''),
                mail_norm = NULLIF(importacion.fn_NormalizarEmail(s.mail_raw), ''),
                tel_norm =
                    NULLIF(REPLACE(REPLACE(REPLACE(REPLACE(s.tel_raw,' ',''),'-',''),'(',''),')',''), '')
            FROM s
        )
        INSERT INTO #Stg (cbu_cvu, esInquilino, dni, nombre, apellido, email, telefono)
        SELECT DISTINCT
            CONVERT(CHAR(22), n.cbu_norm),
            CASE 
                WHEN n.inq_norm COLLATE DATABASE_DEFAULT IN (N'si',N'sí',N'true',N'1',N'inquilino') THEN 1
                WHEN n.inq_norm COLLATE DATABASE_DEFAULT IN (N'no',N'false',N'0',N'propietario') THEN 0
            END,
            n.dni_norm,
            CASE WHEN n.nom_norm  IS NULL THEN NULL ELSE LEFT(n.nom_norm ,100) END,
            CASE WHEN n.ape_norm  IS NULL THEN NULL ELSE LEFT(n.ape_norm ,100) END,
            CASE
                WHEN n.mail_norm IS NULL THEN NULL
                -- si no tiene @, lo descartamos
                WHEN CHARINDEX('@', n.mail_norm) = 0 THEN NULL
                -- si no hay punto después del @, también lo descartamos
                WHEN CHARINDEX('.', n.mail_norm, CHARINDEX('@', n.mail_norm) + 1) = 0 THEN NULL
                ELSE LEFT(n.mail_norm, 255)
            END,
            CASE WHEN n.tel_norm  IS NULL THEN NULL ELSE LEFT(n.tel_norm ,50)  END
        FROM n
        WHERE n.cbu_norm IS NOT NULL
          AND LEN(n.cbu_norm)=22
          AND n.cbu_norm NOT LIKE '%[^0-9]%'
          AND n.inq_norm IS NOT NULL
          AND n.inq_norm COLLATE DATABASE_DEFAULT IN
              (N'si',N'sí',N'true',N'1',N'inquilino', N'no',N'false',N'0',N'propietario');

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasStg INT = (SELECT COUNT(*) FROM #Stg);
            DECLARE @Det2 NVARCHAR(4000) = CONCAT(N'filas_stg_validas=', CONVERT(NVARCHAR(20), @FilasStg));
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'STG listo',
                 @Detalle       = @Det2,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END;

                /* 3) UPSERT en app.Tbl_Persona (UPDATE + INSERT, dinámico según columnas reales) */

        DECLARE @ColsTarget NVARCHAR(MAX) = N'CBU_CVU';
        DECLARE @ColsSource NVARCHAR(MAX) = N's.cbu_cvu';
        DECLARE @SetList    NVARCHAR(MAX) = N'';

        -- Armamos dinámicamente las columnas opcionales
        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'dni')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', dni');
            SET @ColsSource = CONCAT(@ColsSource, N', s.dni');
            SET @SetList    = CONCAT(@SetList,
                                     CASE WHEN @SetList = N'' THEN N'' ELSE N', ' END,
                                     N'p.dni = COALESCE(s.dni, p.dni)');
        END;

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'nombre')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', nombre');
            SET @ColsSource = CONCAT(@ColsSource, N', s.nombre');
            SET @SetList    = CONCAT(@SetList,
                                     CASE WHEN @SetList = N'' THEN N'' ELSE N', ' END,
                                     N'p.nombre = COALESCE(s.nombre, p.nombre)');
        END;

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'apellido')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', apellido');
            SET @ColsSource = CONCAT(@ColsSource, N', s.apellido');
            SET @SetList    = CONCAT(@SetList,
                                     CASE WHEN @SetList = N'' THEN N'' ELSE N', ' END,
                                     N'p.apellido = COALESCE(s.apellido, p.apellido)');
        END;

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'email')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', email');
            SET @ColsSource = CONCAT(@ColsSource, N', s.email');
            SET @SetList    = CONCAT(@SetList,
                                     CASE WHEN @SetList = N'' THEN N'' ELSE N', ' END,
                                     N'p.email = COALESCE(s.email, p.email)');
        END;

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'telefono')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', telefono');
            SET @ColsSource = CONCAT(@ColsSource, N', s.telefono');
            SET @SetList    = CONCAT(@SetList,
                                     CASE WHEN @SetList = N'' THEN N'' ELSE N', ' END,
                                     N'p.telefono = COALESCE(s.telefono, p.telefono)');
        END;

        ---------------------------------------------------------
        -- 3.a) UPDATE de personas ya existentes (mismo CBU_CVU)
        ---------------------------------------------------------
        DECLARE @PersonasActualizadas INT = 0;
        DECLARE @SqlUpdPer NVARCHAR(MAX);

        IF @SetList <> N''
        BEGIN
            SET @SqlUpdPer =
                CONCAT(
                    N'UPDATE p SET ', @SetList, N' ',
                    N'FROM app.Tbl_Persona p ',
                    N'JOIN #Stg s ON s.cbu_cvu = p.CBU_CVU;'
                );

            EXEC (@SqlUpdPer);
            SET @PersonasActualizadas = @@ROWCOUNT;
        END;

        ---------------------------------------------------------
        -- 3.b) INSERT solo de las personas que faltan (por CBU)
        ---------------------------------------------------------
        DECLARE @PersonasNuevas INT =
        (
            SELECT COUNT(*)
            FROM (
                SELECT DISTINCT s.cbu_cvu
                FROM #Stg s
                WHERE s.cbu_cvu IS NOT NULL
                  AND NOT EXISTS (
                        SELECT 1
                        FROM app.Tbl_Persona p
                        WHERE p.CBU_CVU = s.cbu_cvu
                  )
            ) q
        );

        DECLARE @SqlInsPer NVARCHAR(MAX) =
            CONCAT(
                N'INSERT INTO app.Tbl_Persona (', @ColsTarget, N') ',
                N'SELECT ', @ColsSource, N' ',
                N'FROM #Stg s ',
                N'WHERE s.cbu_cvu IS NOT NULL ',
                N'  AND NOT EXISTS (SELECT 1 FROM app.Tbl_Persona p WHERE p.CBU_CVU = s.cbu_cvu);'
            );

        EXEC (@SqlInsPer);

        IF @Verbose = 1
        BEGIN
            DECLARE @Det3 NVARCHAR(4000) =
                CONCAT(N'personas_actualizadas=', CONVERT(NVARCHAR(20), @PersonasActualizadas),
                       N'; personas_nuevas=',      CONVERT(NVARCHAR(20), @PersonasNuevas));
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'Personas upsert (update + insert)',
                 @Detalle       = @Det3,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END;

        /* 4) VINCULAR Persona y Consorcio por el MISMO CBU_CVU y upsert en UFPersona */
        IF OBJECT_ID('tempdb..#MatchCBU','U') IS NOT NULL DROP TABLE #MatchCBU;
        CREATE TABLE #MatchCBU
        (
            idPersona    INT NOT NULL,
            idConsorcio  INT NOT NULL,
            esInquilino  BIT NOT NULL
        );

        INSERT INTO #MatchCBU (idPersona, idConsorcio, esInquilino)
        SELECT
            p.idPersona,
            u.idConsorcio,
            s.esInquilino
        FROM #Stg s
        JOIN app.Tbl_Persona        p ON p.CBU_CVU = s.cbu_cvu
        JOIN app.Tbl_UnidadFuncional u WITH (INDEX = UQ_UnidadFuncional_CBU_CVU)
          ON u.CBU_CVU = s.cbu_cvu;

        IF @Verbose = 1
        BEGIN
            DECLARE @Det4 NVARCHAR(4000) =
                CONCAT(N'matcheos_cbu=', CONVERT(NVARCHAR(20), (SELECT COUNT(*) FROM #MatchCBU)));
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'Match Persona↔Consorcio por CBU', @Det4, @RutaArchivo, @LogPath;
        END;

        -- UPDATE si ya existe (idPersona + idConsorcio)
        UPDATE uf
           SET uf.esInquilino = m.esInquilino
        FROM app.Tbl_UFPersona uf
        JOIN #MatchCBU m
          ON m.idPersona   = uf.idPersona
         AND m.idConsorcio = uf.idConsorcio;

        DECLARE @RowsUpd INT = @@ROWCOUNT;

        -- INSERT si no existe (idPersona + idConsorcio)
        INSERT INTO app.Tbl_UFPersona (idPersona, idConsorcio, esInquilino)
        SELECT m.idPersona, m.idConsorcio, m.esInquilino
        FROM #MatchCBU m
        WHERE NOT EXISTS (
            SELECT 1
            FROM app.Tbl_UFPersona uf
            WHERE uf.idPersona   = m.idPersona
              AND uf.idConsorcio = m.idConsorcio
        );

        DECLARE @RowsIns INT = @@ROWCOUNT;

        /* 5) Resumen final */
        DECLARE @TotCsv    INT = (SELECT COUNT(*) FROM #Raw);
        DECLARE @TotStg    INT = (SELECT COUNT(*) FROM #Stg);
        DECLARE @TotMatch  INT = (SELECT COUNT(*) FROM #MatchCBU);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetFin NVARCHAR(4000) =
                CONCAT(N'csv=',        CONVERT(NVARCHAR(20), @TotCsv),
                       N'; stg=',      CONVERT(NVARCHAR(20), @TotStg),
                       N'; match_cbu=',CONVERT(NVARCHAR(20), @TotMatch),
                       N'; uf_upd=',   CONVERT(NVARCHAR(20), @RowsUpd),
                       N'; uf_ins=',   CONVERT(NVARCHAR(20), @RowsIns));
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'Fin OK', @DetFin, @RutaArchivo, @LogPath;
        END;

        SELECT
            filas_csv_total   = @TotCsv,
            filas_validas_stg = @TotStg,
            vinculos_por_cbu  = @TotMatch,
            uf_actualizadas   = @RowsUpd,
            uf_insertadas     = @RowsIns,
            mensaje           = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) =
            CONCAT(N'Error en línea ', CONVERT(NVARCHAR(10), ERROR_LINE()));
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END;
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarPagosDesdeCsv
    @RutaArchivo      NVARCHAR(4000),
    @HDR              BIT           = 1,
    @Separador        CHAR(1)       = ',',
    @RowTerminator    NVARCHAR(10)  = N'0x0d0a',
    @CodePage         NVARCHAR(16)  = N'65001',
    @LogPath          NVARCHAR(4000) = NULL,
    @Verbose          BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarPagosDesdeCsv';

    BEGIN TRY
        /* =============================== 0) INICIO =============================== */
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* Limpieza previa */
        IF OBJECT_ID('tempdb..#raw')             IS NOT NULL DROP TABLE #raw;
        IF OBJECT_ID('tempdb..#norm')            IS NOT NULL DROP TABLE #norm;
        IF OBJECT_ID('tempdb..#pagos')           IS NOT NULL DROP TABLE #pagos;
        IF OBJECT_ID('tempdb..#errores')         IS NOT NULL DROP TABLE #errores;
        IF OBJECT_ID('tempdb..#pagos_completos') IS NOT NULL DROP TABLE #pagos_completos;
        IF OBJECT_ID('tempdb..#ok')              IS NOT NULL DROP TABLE #ok;

        /* Tablas temporales */
        CREATE TABLE #raw (
            c1 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c2 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c3 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c4 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c5 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c6 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL
        );

        CREATE TABLE #norm (
            id_pago_txt NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            fecha_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            cbu_txt     NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            valor_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL
        );

        CREATE TABLE #pagos (
            fecha       DATE          NOT NULL,
            CBU_CVU     CHAR(22)      COLLATE DATABASE_DEFAULT NOT NULL,
            valor       DECIMAL(10,2) NOT NULL
        );

        CREATE TABLE #errores (
            motivo      NVARCHAR(200)  COLLATE DATABASE_DEFAULT,
            fecha_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT,
            cbu_txt     NVARCHAR(4000) COLLATE DATABASE_DEFAULT,
            valor_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT
        );

        /* =============================== 1) BULK =============================== */
        DECLARE @PrimeraFila INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @SqlBulk NVARCHAR(MAX) =
            CONCAT(
                N'BULK INSERT #raw FROM ''', @RutaEsc, N''' WITH (',
                N' FIRSTROW = ', CONVERT(NVARCHAR(10), @PrimeraFila),
                N', FIELDTERMINATOR = ''', @Separador, N'''',
                N', ROWTERMINATOR  = ''', @RowTerminator, N'''',
                N', CODEPAGE       = ''', @CodePage, N'''',
                N', TABLOCK );'
            );

        BEGIN TRY
            EXEC (@SqlBulk);
        END TRY
        BEGIN CATCH
            DECLARE @Emsg NVARCHAR(4000) = ERROR_MESSAGE();
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR',
                 N'BULK INSERT', @Emsg, @RutaArchivo, @LogPath;
            THROW;
        END CATCH

        DECLARE @FilasRaw INT = (SELECT COUNT(*) FROM #raw);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetRaw NVARCHAR(4000) =
                CONCAT(N'filas_raw=', CONVERT(NVARCHAR(20), @FilasRaw));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'CSV leído', @DetRaw, @RutaArchivo, @LogPath;
        END

        /* =============================== 2) Normalización =============================== */
        INSERT INTO #norm (id_pago_txt, fecha_txt, cbu_txt, valor_txt)
        SELECT
            CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c1 ELSE NULL END,
            CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c2 ELSE c1 END,
            CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c3 ELSE c2 END,
            CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c4 ELSE c3 END
        FROM #raw;

        DECLARE @FilasNorm INT = (SELECT COUNT(*) FROM #norm);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetNorm NVARCHAR(4000) =
                CONCAT(N'filas_norm=', CONVERT(NVARCHAR(20), @FilasNorm));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Normalización lista', @DetNorm, @RutaArchivo, @LogPath;
        END

        /* =============================== 3) Parseo -> #pagos =============================== */
        ;WITH pre AS (
            SELECT
                fecha_txt,
                /* limpio CBU de separadores comunes y espacios/tab/NBSP */
                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(cbu_txt)),
                    NCHAR(160),N''), CHAR(9), N''), ' ', ''), '.', ''), '-', '') AS cbu_clean,
                /* recorto símbolos de moneda y espacios raros */
                LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(valor_txt, NCHAR(160), N' '), CHAR(9), N' '), N'$',''))) AS valor_clean
            FROM #norm
        ),
        parsed AS (
            SELECT
                COALESCE(
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''), 103), -- dd/mm/yyyy
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''), 120), -- yyyy-mm-dd
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''))      -- genérico
                ) AS fecha,
                /* pad-left a 22 */
                CAST(RIGHT(CONCAT(REPLICATE('0',22), cbu_clean), 22) AS CHAR(22)) AS CBU_CVU,
                /* parser flexible: soporta 12.345,67 y 12,345.67 */
                importacion.fn_ParseImporteFlexible(NULLIF(valor_clean, N''))     AS valor
            FROM pre
        )
        INSERT INTO #pagos (fecha, CBU_CVU, valor)
        SELECT fecha, CBU_CVU, valor
        FROM parsed
        WHERE fecha IS NOT NULL
          AND valor IS NOT NULL
          AND CBU_CVU IS NOT NULL
          AND CBU_CVU <> REPLICATE('0',22);  -- evita CBUs vacíos formateados

        DECLARE @FilasPagos INT = (SELECT COUNT(*) FROM #pagos);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetPagos NVARCHAR(4000) =
                CONCAT(N'pagos_validos=', CONVERT(NVARCHAR(20), @FilasPagos));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Parseo de pagos', @DetPagos, @RutaArchivo, @LogPath;
        END

        /* Errores de parseo */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT
            N'Fila inválida (fecha/valor/CBU)',
            n.fecha_txt, n.cbu_txt, n.valor_txt
        FROM #norm n
        WHERE NOT EXISTS (
            SELECT 1
            FROM #pagos p
            WHERE p.CBU_CVU = CAST(
                     RIGHT(CONCAT(REPLICATE('0',22),
                                  REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(n.cbu_txt)),
                                        NCHAR(160),N''), CHAR(9), N''), ' ', ''), '.', ''), '-', '')
                     ), 22) AS CHAR(22))
              AND p.fecha = COALESCE(
                                TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''), 103),
                                TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''), 120),
                                TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),'')))
        );

        DECLARE @ErroresParseo INT = (SELECT COUNT(*) FROM #errores);

        /* =============================== 4) Enriquecer (UF/Consorcio/Expensa) =============================== */
        ;WITH pagos_enriq AS
        (
            SELECT
                p.fecha,
                p.valor                AS monto,
                p.CBU_CVU,
                uf.idUnidadFuncional,
                uf.idConsorcio
            FROM #pagos p
            LEFT JOIN app.Tbl_UnidadFuncional uf
                   ON uf.CBU_CVU = p.CBU_CVU
        )
        SELECT
            pe.*,
            e.nroExpensa
        INTO #pagos_completos
        FROM pagos_enriq pe
        CROSS APPLY (VALUES (DATEFROMPARTS(YEAR(pe.fecha), MONTH(pe.fecha), 1))) AS m(inicioMes)
        OUTER APPLY
        (
            /* Rango: [primer día del mes, primer día del mes siguiente) */
            SELECT TOP (1) e.nroExpensa
            FROM app.Tbl_Expensa e
            WHERE e.idConsorcio = pe.idConsorcio
              AND e.fechaGeneracion >= m.inicioMes
              AND e.fechaGeneracion <  DATEADD(MONTH, 1, m.inicioMes)
            ORDER BY e.fechaGeneracion DESC, e.nroExpensa DESC
        ) e;

        /* Registrar faltantes de mapeo (UF/consorcio/expensa) */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT
            CASE 
              WHEN idUnidadFuncional IS NULL THEN N'No se encontró UF para ese CBU'
              WHEN idConsorcio IS NULL       THEN N'No se determinó Consorcio'
              WHEN nroExpensa IS NULL        THEN N'No hay expensa del mes para el consorcio'
            END,
            CONVERT(NVARCHAR(30), fecha, 121),
            CBU_CVU,
            CONVERT(NVARCHAR(40), monto)
        FROM #pagos_completos
        WHERE idUnidadFuncional IS NULL
           OR idConsorcio IS NULL
           OR nroExpensa IS NULL;

           SELECT * FROM app.Tbl_EstadoCuenta;

        /* Registrar filas sin EstadoCuenta */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT
            N'No existe EstadoCuenta para UF/Consorcio/Expensa',
            CONVERT(NVARCHAR(30), p.fecha, 121),
            p.CBU_CVU,
            CONVERT(NVARCHAR(40), p.monto)
        FROM #pagos_completos p
        WHERE p.idUnidadFuncional IS NOT NULL
          AND p.idConsorcio IS NOT NULL
          AND p.nroExpensa IS NOT NULL
          AND NOT EXISTS (
                SELECT 1
                FROM app.Tbl_EstadoCuenta ec
                WHERE ec.nroUnidadFuncional = p.idUnidadFuncional
                  AND ec.idConsorcio       = p.idConsorcio
                  AND ec.nroExpensa        = p.nroExpensa
          );

        /* Filas válidas (con mapeo completo Y EstadoCuenta existente) */
        IF OBJECT_ID('tempdb..#ok') IS NOT NULL DROP TABLE #ok;

        SELECT DISTINCT   -- evita duplicados si el CSV repite filas
            p.fecha,
            p.monto,
            p.CBU_CVU,
            p.idUnidadFuncional,
            p.idConsorcio,
            p.nroExpensa,
            ec.idEstadoCuenta
        INTO #ok
        FROM #pagos_completos p
        JOIN app.Tbl_EstadoCuenta ec
          ON ec.nroUnidadFuncional = p.idUnidadFuncional
         AND ec.idConsorcio       = p.idConsorcio
         AND ec.nroExpensa        = p.nroExpensa
        WHERE p.idUnidadFuncional IS NOT NULL
          AND p.idConsorcio IS NOT NULL
          AND p.nroExpensa IS NOT NULL;

        DECLARE @ErroresMatch       INT = (SELECT COUNT(*) FROM #errores) - @ErroresParseo;
        DECLARE @FilasOK            INT = (SELECT COUNT(*) FROM #ok);
        DECLARE @PagosNoAsociados   INT = (SELECT COUNT(*) FROM #errores);

        IF @Verbose = 1
        BEGIN
            IF @ErroresMatch > 0
            BEGIN
                DECLARE @DetErrMatchMsg NVARCHAR(4000) =
                    CONCAT(N'falla_match=', CONVERT(NVARCHAR(20), @ErroresMatch));
                EXEC reportes.Sp_LogReporte @Procedimiento, 'WARN',
                     N'Filas sin mapping completo', @DetErrMatchMsg, @RutaArchivo, @LogPath;
            END;

            DECLARE @DetOkMsg NVARCHAR(4000) =
                CONCAT(N'pagos_ok=', CONVERT(NVARCHAR(20), @FilasOK));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Filas listas para inserción', @DetOkMsg, @RutaArchivo, @LogPath;
        END

        /* =============================== 4.b) Pagos no asociados (idempotente) =============================== */
        IF OBJECT_ID('importacion.Tbl_Pago_No_Asociado', 'U') IS NOT NULL
        BEGIN
            INSERT INTO importacion.Tbl_Pago_No_Asociado
                (motivo, fecha_txt, cbu_txt, valor_txt, rutaArchivo)
            SELECT e.motivo, e.fecha_txt, e.cbu_txt, e.valor_txt, @RutaArchivo
            FROM #errores e
            WHERE NOT EXISTS (
                SELECT 1
                FROM importacion.Tbl_Pago_No_Asociado x
                WHERE x.motivo      = e.motivo
                  AND x.fecha_txt   = e.fecha_txt
                  AND x.cbu_txt     = e.cbu_txt
                  AND x.valor_txt   = e.valor_txt
                  AND x.rutaArchivo = @RutaArchivo
            );

            IF @Verbose = 1
            BEGIN
                DECLARE @DetNoAsocMsg NVARCHAR(4000) =
                    CONCAT(N'pagos_no_asociados=', CONVERT(NVARCHAR(20), @PagosNoAsociados));
                EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                     N'Pagos no asociados registrados', @DetNoAsocMsg, @RutaArchivo, @LogPath;
            END
        END  -- <<<<<< ¡Este END faltaba y rompía el TRY/CATCH! >>>>>>

        /* =============================== 5) INSERTAR PAGOS (IDEMPOTENTE) =============================== */
        IF OBJECT_ID('tempdb..#merge_out_pagos') IS NOT NULL DROP TABLE #merge_out_pagos;
        CREATE TABLE #merge_out_pagos (accion NVARCHAR(10));

        ;WITH src AS (
            SELECT
                o.idEstadoCuenta,
                o.idUnidadFuncional AS nroUnidadFuncional,
                o.idConsorcio,
                o.nroExpensa,
                o.fecha,
                o.monto,
                o.CBU_CVU
            FROM #ok o
        )
        MERGE app.Tbl_Pago AS T
        USING src AS S
           ON  T.idEstadoCuenta     = S.idEstadoCuenta
           AND T.nroUnidadFuncional = S.nroUnidadFuncional
           AND T.idConsorcio        = S.idConsorcio
           AND T.nroExpensa         = S.nroExpensa
           AND T.fecha              = S.fecha
           AND T.monto              = S.monto
           AND T.CBU_CVU            = S.CBU_CVU
        WHEN NOT MATCHED THEN
            INSERT (idEstadoCuenta, nroUnidadFuncional, idConsorcio, nroExpensa,
                    fecha, monto, CBU_CVU)
            VALUES (S.idEstadoCuenta, S.nroUnidadFuncional, S.idConsorcio, S.nroExpensa,
                    S.fecha, S.monto, S.CBU_CVU)
        OUTPUT $action INTO #merge_out_pagos;

        DECLARE @PagosInsertados INT =
            (SELECT COUNT(*) FROM #merge_out_pagos WHERE accion = 'INSERT');

        IF @Verbose = 1
        BEGIN
            DECLARE @DetInsMsg NVARCHAR(4000) =
                CONCAT(N'pagos_insertados=', CONVERT(NVARCHAR(20), @PagosInsertados));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Pagos insertados (idempotente)', @DetInsMsg, @RutaArchivo, @LogPath;
        END

        /* =============================== 6) Resumen =============================== */
        DECLARE @Resumen NVARCHAR(4000);
        SET @Resumen =
            CONCAT(
                N'raw=', @FilasRaw,
                N'; norm=', @FilasNorm,
                N'; pagos_validos=', @FilasPagos,
                N'; errores_parseo=', @ErroresParseo,
                N'; errores_match=', @ErroresMatch,
                N'; pagos_no_asociados=', @PagosNoAsociados,
                N'; pagos_listos=', @FilasOK,
                N'; pagos_ins_total(tras merge)=', @PagosInsertados
            );

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Fin OK', @Resumen, @RutaArchivo, @LogPath;

        SELECT
            filas_raw             = @FilasRaw,
            filas_norm            = @FilasNorm,
            pagos_validos         = @FilasPagos,
            errores_parseo        = @ErroresParseo,
            errores_match         = @ErroresMatch,
            pagos_no_asociados    = @PagosNoAsociados,
            pagos_listos          = @FilasOK,
            pagos_insertados      = @PagosInsertados,
            mensaje               = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) =
            CONCAT(N'Error en línea ', CONVERT(NVARCHAR(10), ERROR_LINE()));
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW; -- correcto: dentro del CATCH
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
-- Cargar un insert de lote de expensas y estado cuenta
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE app.Sp_GenerarEstadoCuentaDesdeExpensas
    @Anio    INT,
    @LogPath NVARCHAR(4000) = NULL,
    @Verbose BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'app.Sp_GenerarEstadoCuentaDesdeExpensas';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'Inicio generación EstadosCuenta', NULL, NULL, @LogPath;

        /* 1) Expensas del año indicado */
        IF OBJECT_ID('tempdb..#exp_anio') IS NOT NULL DROP TABLE #exp_anio;

        SELECT
            e.idConsorcio,
            e.nroExpensa,
            e.fechaGeneracion
        INTO #exp_anio
        FROM app.Tbl_Expensa e
        WHERE YEAR(e.fechaGeneracion) = @Anio;

        DECLARE @ExpensasAnio INT = (SELECT COUNT(*) FROM #exp_anio);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetExp NVARCHAR(4000) =
                N'expensas_anio=' + CONVERT(NVARCHAR(20), @ExpensasAnio);
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'Expensas a procesar', @DetExp, NULL, @LogPath;
        END

        /* 2) Crear EstadosCuenta para cada UF de cada expensa (evitando duplicados) */
        INSERT INTO app.Tbl_EstadoCuenta (nroUnidadFuncional, idConsorcio, nroExpensa)
        SELECT
            uf.idUnidadFuncional         AS nroUnidadFuncional,
            ea.idConsorcio,
            ea.nroExpensa
        FROM #exp_anio ea
        JOIN app.Tbl_UnidadFuncional uf
          ON uf.idConsorcio = ea.idConsorcio
        WHERE NOT EXISTS (
            SELECT 1
            FROM app.Tbl_EstadoCuenta ec
            WHERE ec.nroUnidadFuncional = uf.idUnidadFuncional
              AND ec.idConsorcio       = ea.idConsorcio
              AND ec.nroExpensa        = ea.nroExpensa
        );

        DECLARE @EstadosCreados INT = @@ROWCOUNT;

        IF @Verbose = 1
        BEGIN
            DECLARE @DetEC NVARCHAR(4000) =
                N'estados_creados=' + CONVERT(NVARCHAR(20), @EstadosCreados);
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'EstadosCuenta generados', @DetEC, NULL, @LogPath;
        END

        /* 3) Fin + resumen */
        DECLARE @Resumen NVARCHAR(4000) =
            N'expensas_anio=' + CONVERT(NVARCHAR(20), @ExpensasAnio) +
            N'; estados_creados=' + CONVERT(NVARCHAR(20), @EstadosCreados);

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'Fin OK', @Resumen, NULL, @LogPath;

        SELECT
            expensas_anio     = @ExpensasAnio,
            estados_creados   = @EstadosCreados,
            mensaje           = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) =
            N'Error en línea ' + CONVERT(NVARCHAR(10), ERROR_LINE());

        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = NULL,
            @RutaLog       = @LogPath;

        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarPagosDesdeCsv
    @RutaArchivo      NVARCHAR(4000),
    @HDR              BIT           = 1,
    @Separador        CHAR(1)       = ',',
    @RowTerminator    NVARCHAR(10)  = '\n',
    @CodePage         NVARCHAR(16)  = N'65001',
    @LogPath          NVARCHAR(4000) = NULL,
    @Verbose          BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarPagosDesdeCsv';

    BEGIN TRY
        /* =============================== 0) INICIO =============================== */
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* Limpieza previa */
        IF OBJECT_ID('tempdb..#raw')             IS NOT NULL DROP TABLE #raw;
        IF OBJECT_ID('tempdb..#norm')            IS NOT NULL DROP TABLE #norm;
        IF OBJECT_ID('tempdb..#pagos')           IS NOT NULL DROP TABLE #pagos;
        IF OBJECT_ID('tempdb..#errores')         IS NOT NULL DROP TABLE #errores;
        IF OBJECT_ID('tempdb..#pagos_completos') IS NOT NULL DROP TABLE #pagos_completos;
        IF OBJECT_ID('tempdb..#ok')              IS NOT NULL DROP TABLE #ok;

        /* Tablas temporales */
        CREATE TABLE #raw (
            c1 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c2 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c3 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c4 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL
        );

        CREATE TABLE #norm (
            id_norm     INT IDENTITY(1,1) PRIMARY KEY,
            id_pago_txt NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            fecha_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            cbu_txt     NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            valor_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL
        );

        CREATE TABLE #pagos (
            id_norm     INT           NOT NULL,
            fecha       DATE          NOT NULL,
            CBU_CVU     CHAR(22)      COLLATE DATABASE_DEFAULT NOT NULL,
            valor       DECIMAL(12,2) NOT NULL
        );

        CREATE TABLE #errores (
            motivo      NVARCHAR(200)  COLLATE DATABASE_DEFAULT,
            fecha_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT,
            cbu_txt     NVARCHAR(4000) COLLATE DATABASE_DEFAULT,
            valor_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT
        );

        /* =============================== 1) BULK =============================== */
        DECLARE @PrimeraFila INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @SqlBulk NVARCHAR(MAX) =
            CONCAT(
                N'BULK INSERT #raw FROM ''', @RutaEsc, N''' WITH (',
                N' FIRSTROW = ', CONVERT(NVARCHAR(10), @PrimeraFila),
                N', FIELDTERMINATOR = ''', @Separador, N'''',
                N', ROWTERMINATOR  = ''', @RowTerminator, N'''',
                N', CODEPAGE       = ''', @CodePage, N'''',
                N', FIELDQUOTE     = ''"''',
                N', TABLOCK );'
            );

        BEGIN TRY
            EXEC (@SqlBulk);
        END TRY
        BEGIN CATCH
            DECLARE @Emsg NVARCHAR(4000) = ERROR_MESSAGE();
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR',
                 N'BULK INSERT', @Emsg, @RutaArchivo, @LogPath;
            THROW;
        END CATCH

        /* Limpieza de caracteres especiales */
        UPDATE r
           SET c1 = REPLACE(REPLACE(REPLACE(c1, CHAR(13), N''), CHAR(10), N''), NCHAR(65279), N''),
               c2 = REPLACE(REPLACE(REPLACE(c2, CHAR(13), N''), CHAR(10), N''), NCHAR(65279), N''),
               c3 = REPLACE(REPLACE(REPLACE(c3, CHAR(13), N''), CHAR(10), N''), NCHAR(65279), N''),
               c4 = REPLACE(REPLACE(REPLACE(c4, CHAR(13), N''), CHAR(10), N''), NCHAR(65279), N'')
        FROM #raw r;

        DECLARE @FilasRaw INT = (SELECT COUNT(*) FROM #raw);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetRaw NVARCHAR(4000) =
                CONCAT(N'filas_raw=', CONVERT(NVARCHAR(20), @FilasRaw));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'CSV leído', @DetRaw, @RutaArchivo, @LogPath;
        END

        /* =============================== 2) Normalización =============================== */
        INSERT INTO #norm (id_pago_txt, fecha_txt, cbu_txt, valor_txt)
        SELECT
            LTRIM(RTRIM(c1)),
            LTRIM(RTRIM(c2)),
            LTRIM(RTRIM(c3)),
            LTRIM(RTRIM(c4))
        FROM #raw
        WHERE NULLIF(LTRIM(RTRIM(c4)), '') IS NOT NULL;

        DECLARE @FilasNorm INT = (SELECT COUNT(*) FROM #norm);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetNorm NVARCHAR(4000) =
                CONCAT(N'filas_norm=', CONVERT(NVARCHAR(20), @FilasNorm));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Normalización lista', @DetNorm, @RutaArchivo, @LogPath;
        END

        /* =============================== 3) Parseo -> #pagos =============================== */
        ;WITH pre AS (
            SELECT
                n.id_norm,
                n.fecha_txt,
                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(UPPER(LTRIM(RTRIM(n.cbu_txt))),
                    NCHAR(160),N''), CHAR(9), N''), ' ', ''), '.', ''), '-', '') AS cbu_clean,
                UPPER(LTRIM(RTRIM(
                    REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(n.valor_txt,
                        NCHAR(160), N' '), CHAR(9), N' '), 'AR$', ''), 'ARS', ''), 'U$S', ''), '$',''), '"','')
                ))) AS v0
            FROM #norm n
        ),
        negfix AS (
            SELECT
                id_norm,
                fecha_txt,
                cbu_clean,
                CASE WHEN v0 LIKE '(%' AND v0 LIKE '%)' THEN 1 ELSE 0 END AS es_neg,
                REPLACE(REPLACE(v0,'(','') ,')','') AS v1
            FROM pre
        ),
        sincar AS (
            SELECT
                id_norm,
                fecha_txt,
                cbu_clean,
                es_neg,
                REPLACE(v1,' ','') AS v2
            FROM negfix
        ),
        cands AS (
            SELECT
                id_norm,
                fecha_txt,
                cbu_clean,
                es_neg,
                v2,
                REPLACE(REPLACE(v2, '.', ''), ',', '.') AS cand_coma,
                REPLACE(REPLACE(v2, ',', ''), '.', '.') AS cand_punto,
                REPLACE(REPLACE(v2, '.', ''), ',', '') AS cand_sin
            FROM sincar
        ),
        decpos AS (
            SELECT
                id_norm, fecha_txt, cbu_clean, es_neg, v2, cand_coma, cand_punto, cand_sin,
                CASE WHEN CHARINDEX('.', cand_coma)  > 0
                     THEN LEN(cand_coma)  - CHARINDEX('.', REVERSE(cand_coma))  END AS dec2_coma,
                CASE WHEN CHARINDEX('.', cand_punto) > 0
                     THEN LEN(cand_punto) - CHARINDEX('.', REVERSE(cand_punto)) END AS dec2_punto
            FROM cands
        ),
        parsed AS (
            SELECT
                n.id_norm,
                COALESCE(
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''), 103),
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''), 120),
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''))      
                ) AS fecha,
                CAST(RIGHT(CONCAT(REPLICATE('0',22), n.cbu_clean), 22) AS CHAR(22)) AS CBU_CVU,
                COALESCE(
                    CASE WHEN n.dec2_punto = 2
                         THEN TRY_CONVERT(DECIMAL(12,2), CASE WHEN n.es_neg=1 THEN '-' + n.cand_punto ELSE n.cand_punto END)
                    END,
                    CASE WHEN n.dec2_coma = 2
                         THEN TRY_CONVERT(DECIMAL(12,2), CASE WHEN n.es_neg=1 THEN '-' + n.cand_coma ELSE n.cand_coma END)
                    END,
                    TRY_CONVERT(DECIMAL(12,2), CASE WHEN n.es_neg=1 THEN '-' + n.cand_punto ELSE n.cand_punto END),
                    TRY_CONVERT(DECIMAL(12,2), CASE WHEN n.es_neg=1 THEN '-' + n.cand_coma  ELSE n.cand_coma  END),
                    TRY_CONVERT(DECIMAL(12,2), CASE WHEN n.es_neg=1 THEN '-' + n.cand_sin   ELSE n.cand_sin   END)
                ) AS valor
            FROM decpos n
        )
        INSERT INTO #pagos (id_norm, fecha, CBU_CVU, valor)
        SELECT id_norm, fecha, CBU_CVU, valor
        FROM parsed
        WHERE fecha IS NOT NULL
          AND valor IS NOT NULL
          AND CBU_CVU IS NOT NULL
          AND CBU_CVU <> REPLICATE('0',22);

        DECLARE @FilasPagos INT = (SELECT COUNT(*) FROM #pagos);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetPagos NVARCHAR(4000) =
                CONCAT(N'pagos_validos=', CONVERT(NVARCHAR(20), @FilasPagos));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Parseo de pagos', @DetPagos, @RutaArchivo, @LogPath;
        END

        /* Errores de parseo */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT N'Fila inválida (fecha/valor/CBU)', n.fecha_txt, n.cbu_txt, n.valor_txt
        FROM #norm n
        LEFT JOIN #pagos p ON p.id_norm = n.id_norm
        WHERE p.id_norm IS NULL;

        DECLARE @ErroresParseo INT = (SELECT COUNT(*) FROM #errores);

        /* =============================== 4) Enriquecer =============================== */
        ;WITH pagos_enriq AS
        (
            SELECT
                p.fecha,
                p.valor AS monto,
                p.CBU_CVU,
                uf.idUnidadFuncional,
                uf.idConsorcio
            FROM #pagos p
            LEFT JOIN app.Tbl_UnidadFuncional uf
           ON RIGHT(
                 CONCAT(REPLICATE('0',22),
                        REPLACE(REPLACE(REPLACE(REPLACE(UPPER(LTRIM(RTRIM(uf.CBU_CVU))),
                                NCHAR(160),N''), CHAR(9), N''), ' ', ''), '-', '')
                 ), 22
              ) = p.CBU_CVU
)
        SELECT
            pe.*,
            e.nroExpensa
        INTO #pagos_completos
        FROM pagos_enriq pe
        CROSS APPLY (VALUES (DATEFROMPARTS(YEAR(pe.fecha), MONTH(pe.fecha), 1))) AS m(inicioMes)
        OUTER APPLY
        (
            SELECT TOP (1) e.nroExpensa
            FROM app.Tbl_Expensa e
            WHERE e.idConsorcio = pe.idConsorcio
              AND e.fechaGeneracion >= m.inicioMes
              AND e.fechaGeneracion <  DATEADD(MONTH, 1, m.inicioMes)
            ORDER BY e.fechaGeneracion DESC, e.nroExpensa DESC
        ) e;

        /* Registrar errores de mapeo */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT
            CASE 
              WHEN idUnidadFuncional IS NULL THEN N'No se encontró UF para ese CBU'
              WHEN idConsorcio IS NULL       THEN N'No se determinó Consorcio'
              WHEN nroExpensa IS NULL        THEN N'No hay expensa del mes para el consorcio'
            END,
            CONVERT(NVARCHAR(30), fecha, 121),
            CBU_CVU,
            CONVERT(NVARCHAR(40), monto)
        FROM #pagos_completos
        WHERE idUnidadFuncional IS NULL
           OR idConsorcio IS NULL
           OR nroExpensa IS NULL;

        /* Registrar filas sin EstadoCuenta */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT
            N'No existe EstadoCuenta para UF/Consorcio/Expensa',
            CONVERT(NVARCHAR(30), p.fecha, 121),
            p.CBU_CVU,
            CONVERT(NVARCHAR(40), p.monto)
        FROM #pagos_completos p
        WHERE p.idUnidadFuncional IS NOT NULL
          AND p.idConsorcio IS NOT NULL
          AND p.nroExpensa IS NOT NULL
          AND NOT EXISTS (
                SELECT 1
                FROM app.Tbl_EstadoCuenta ec
                WHERE ec.nroUnidadFuncional = p.idUnidadFuncional
                  AND ec.idConsorcio       = p.idConsorcio
                  AND ec.nroExpensa        = p.nroExpensa
          );

        /* Filas válidas */
        SELECT DISTINCT
            p.fecha,
            p.monto,
            p.CBU_CVU,
            p.idUnidadFuncional,
            p.idConsorcio,
            p.nroExpensa,
            ec.idEstadoCuenta
        INTO #ok
        FROM #pagos_completos p
        JOIN app.Tbl_EstadoCuenta ec
          ON ec.nroUnidadFuncional = p.idUnidadFuncional
         AND ec.idConsorcio       = p.idConsorcio
         AND ec.nroExpensa        = p.nroExpensa
        WHERE p.idUnidadFuncional IS NOT NULL
          AND p.idConsorcio IS NOT NULL
          AND p.nroExpensa IS NOT NULL;

        DECLARE @ErroresMatch       INT = (SELECT COUNT(*) FROM #errores) - @ErroresParseo;
        DECLARE @FilasOK            INT = (SELECT COUNT(*) FROM #ok);
        DECLARE @PagosNoAsociados   INT = (SELECT COUNT(*) FROM #errores);

        IF @Verbose = 1
        BEGIN
            IF @ErroresMatch > 0
            BEGIN
                DECLARE @DetErrMatchMsg NVARCHAR(4000) =
                    CONCAT(N'falla_match=', CONVERT(NVARCHAR(20), @ErroresMatch));
                EXEC reportes.Sp_LogReporte @Procedimiento, 'WARN',
                     N'Filas sin mapping completo', @DetErrMatchMsg, @RutaArchivo, @LogPath;
            END;

            DECLARE @DetOkMsg NVARCHAR(4000) =
                CONCAT(N'pagos_ok=', CONVERT(NVARCHAR(20), @FilasOK));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Filas listas para inserción', @DetOkMsg, @RutaArchivo, @LogPath;
        END

        /* =============================== 4.b) Pagos no asociados =============================== */
        IF OBJECT_ID('importacion.Tbl_Pago_No_Asociado', 'U') IS NOT NULL
        BEGIN
            INSERT INTO importacion.Tbl_Pago_No_Asociado
                (motivo, fecha_txt, cbu_txt, valor_txt, rutaArchivo)
            SELECT e.motivo, e.fecha_txt, e.cbu_txt, e.valor_txt, @RutaArchivo
            FROM #errores e
            WHERE NOT EXISTS (
                SELECT 1
                FROM importacion.Tbl_Pago_No_Asociado x
                WHERE x.motivo      = e.motivo
                  AND x.fecha_txt   = e.fecha_txt
                  AND x.cbu_txt     = e.cbu_txt
                  AND x.valor_txt   = e.valor_txt
                  AND x.rutaArchivo = @RutaArchivo
            );

            IF @Verbose = 1
            BEGIN
                DECLARE @DetNoAsocMsg NVARCHAR(4000) =
                    CONCAT(N'pagos_no_asociados=', CONVERT(NVARCHAR(20), @PagosNoAsociados));
                EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                     N'Pagos no asociados registrados', @DetNoAsocMsg, @RutaArchivo, @LogPath;
            END
        END

        /* =============================== 5) INSERTAR PAGOS =============================== */
        IF OBJECT_ID('tempdb..#merge_out_pagos') IS NOT NULL DROP TABLE #merge_out_pagos;
        CREATE TABLE #merge_out_pagos (accion NVARCHAR(10));

        ;WITH src AS (
            SELECT
                o.idEstadoCuenta,
                o.idUnidadFuncional AS nroUnidadFuncional,
                o.idConsorcio,
                o.nroExpensa,
                o.fecha,
                o.monto,
                o.CBU_CVU
            FROM #ok o
        )
        MERGE app.Tbl_Pago AS T
        USING src AS S
           ON  T.idEstadoCuenta     = S.idEstadoCuenta
           AND T.nroUnidadFuncional = S.nroUnidadFuncional
           AND T.idConsorcio        = S.idConsorcio
           AND T.nroExpensa         = S.nroExpensa
           AND T.fecha              = S.fecha
           AND T.monto              = S.monto
           AND T.CBU_CVU            = S.CBU_CVU
        WHEN NOT MATCHED THEN
            INSERT (idEstadoCuenta, nroUnidadFuncional, idConsorcio, nroExpensa,
                    fecha, monto, CBU_CVU)
            VALUES (S.idEstadoCuenta, S.nroUnidadFuncional, S.idConsorcio, S.nroExpensa,
                    S.fecha, S.monto, S.CBU_CVU)
        OUTPUT $action INTO #merge_out_pagos;

        DECLARE @PagosInsertados INT =
            (SELECT COUNT(*) FROM #merge_out_pagos WHERE accion = 'INSERT');

        IF @Verbose = 1
        BEGIN
            DECLARE @DetInsMsg NVARCHAR(4000) =
                CONCAT(N'pagos_insertados=', CONVERT(NVARCHAR(20), @PagosInsertados));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Pagos insertados (idempotente)', @DetInsMsg, @RutaArchivo, @LogPath;
        END

        /* =============================== 6) Resumen =============================== */
        DECLARE @Resumen NVARCHAR(4000);
        SET @Resumen =
            CONCAT(
                N'raw=', @FilasRaw,
                N'; norm=', @FilasNorm,
                N'; pagos_validos=', @FilasPagos,
                N'; errores_parseo=', @ErroresParseo,
                N'; errores_match=', @ErroresMatch,
                N'; pagos_no_asociados=', @PagosNoAsociados,
                N'; pagos_listos=', @FilasOK,
                N'; pagos_ins_total=', @PagosInsertados
            );

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Fin OK', @Resumen, @RutaArchivo, @LogPath;

        SELECT
            filas_raw             = @FilasRaw,
            filas_norm            = @FilasNorm,
            pagos_validos         = @FilasPagos,
            errores_parseo        = @ErroresParseo,
            errores_match         = @ErroresMatch,
            pagos_no_asociados    = @PagosNoAsociados,
            pagos_listos          = @FilasOK,
            pagos_insertados      = @PagosInsertados,
            mensaje               = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) =
            CONCAT(N'Error en línea ', CONVERT(NVARCHAR(10), ERROR_LINE()));
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE app.Sp_CargarGastosExtraordinariosIniciales
    @Verbose BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    /* 0) Alinear con consorcios de prueba */
    DECLARE
        @idCons_Test1 INT,
        @idCons_Test2 INT,
        @idCons_Test3 INT,
        @idCons_Test4 INT;

    -- Asegurar consorcios de prueba por nombre (se crean si no existen)
    IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_1_FULL_BC')
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        VALUES ('CONSORCIO_TEST_1_FULL_BC', NULL, NULL);

    IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_2_SIN_BC')
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        VALUES ('CONSORCIO_TEST_2_SIN_BC', NULL, NULL);

    IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_3_SOLO_BAULERA')
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        VALUES ('CONSORCIO_TEST_3_SOLO_BAULERA', NULL, NULL);

    IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_4_SOLO_COCHERA')
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        VALUES ('CONSORCIO_TEST_4_SOLO_COCHERA', NULL, NULL);

    SELECT @idCons_Test1 = idConsorcio
    FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_1_FULL_BC';

    SELECT @idCons_Test2 = idConsorcio
    FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_2_SIN_BC';

    SELECT @idCons_Test3 = idConsorcio
    FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_3_SOLO_BAULERA';

    SELECT @idCons_Test4 = idConsorcio
    FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_4_SOLO_COCHERA';

    IF OBJECT_ID('tempdb..#GastosTemp') IS NOT NULL DROP TABLE #GastosTemp;
    CREATE TABLE #GastosTemp (
        idConsorcio   INT,
        descripcion   VARCHAR(200) COLLATE DATABASE_DEFAULT,
        fechaEmision  DATE,
        importe       DECIMAL(10,2),
        cuotaActual   TINYINT,
        cantCuotas    TINYINT
    );

    /* Casos de prueba (incluye uno en marzo 2025 para CONSORCIO_TEST_1_FULL_BC) */
    INSERT INTO #GastosTemp (idConsorcio, descripcion, fechaEmision, importe, cuotaActual, cantCuotas)
    VALUES
      -- Este es el que te asegura extraordinarias en la expensa de marzo 2025
      (@idCons_Test1, 'Obra extraordinaria fachada y balcones (marzo 2025)', '2025-03-07', 145000.00, 1, 7),

      (@idCons_Test2, 'Renovación total del sistema eléctrico del edificio', '2025-07-06', 230000.00, 2, 5),
      (@idCons_Test3, 'Instalación de sistema contra incendios',             '2025-04-22', 100000.00, 1, 2),
      (@idCons_Test4, 'Impermeabilización y refacción de techo',             '2025-12-30', 500000.00, 1, 1);

    /* 1) Asegurar consorcios (si los Ids no existen aún)
          (en la práctica no debería dispararse porque arriba ya se crean por nombre)
    */
    IF EXISTS (SELECT 1 FROM #GastosTemp gt
               LEFT JOIN app.Tbl_Consorcio c ON c.idConsorcio = gt.idConsorcio
               WHERE c.idConsorcio IS NULL)
    BEGIN
        SET IDENTITY_INSERT app.Tbl_Consorcio ON;
        INSERT INTO app.Tbl_Consorcio (idConsorcio, nombre)
        SELECT DISTINCT gt.idConsorcio, CONCAT('Consorcio ', gt.idConsorcio)
        FROM #GastosTemp gt
        LEFT JOIN app.Tbl_Consorcio c ON c.idConsorcio = gt.idConsorcio
        WHERE c.idConsorcio IS NULL;
        SET IDENTITY_INSERT app.Tbl_Consorcio OFF;
    END

    /* 2) Expensas por (Consorcio, fechaEmision) */
    IF OBJECT_ID('tempdb..#Exp') IS NOT NULL DROP TABLE #Exp;
    CREATE TABLE #Exp (
        idConsorcio INT PRIMARY KEY,
        fecha       DATE,
        nroExpensa  INT
    );

    -- Crear las que falten (usa fechaEmision como fechaGeneracion;
    -- en nuestro caso para marzo 2025 coincide con la esperada 2025-03-07)
    INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
    SELECT DISTINCT gt.idConsorcio, gt.fechaEmision, NULL, NULL, 0
    FROM #GastosTemp gt
    WHERE NOT EXISTS (
        SELECT 1 FROM app.Tbl_Expensa e
        WHERE e.idConsorcio     = gt.idConsorcio
          AND e.fechaGeneracion = gt.fechaEmision
    );

    -- Cargar mapeo a temp
    INSERT INTO #Exp(idConsorcio, fecha, nroExpensa)
    SELECT e.idConsorcio, e.fechaGeneracion, e.nroExpensa
    FROM app.Tbl_Expensa e
    JOIN (SELECT DISTINCT idConsorcio, fechaEmision FROM #GastosTemp) d
      ON d.idConsorcio = e.idConsorcio AND d.fechaEmision = e.fechaGeneracion;

    /* 3) Insertar GASTO Extraordinario evitando duplicados */
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    SELECT x.nroExpensa, gt.idConsorcio, 'Extraordinario', gt.descripcion, gt.fechaEmision, gt.importe
    FROM #GastosTemp gt
    JOIN #Exp x ON x.idConsorcio = gt.idConsorcio AND x.fecha = gt.fechaEmision
    WHERE NOT EXISTS (
        SELECT 1
        FROM app.Tbl_Gasto g
        WHERE g.idConsorcio = gt.idConsorcio
          AND g.nroExpensa  = x.nroExpensa
          AND g.tipo        = 'Extraordinario'
          AND ISNULL(g.descripcion,'') = ISNULL(gt.descripcion,'')
    );

    /* 4) Detalle Extraordinario: solo si falta para esos gastos */
    INSERT INTO app.Tbl_Gasto_Extraordinario (idGasto, cuotaActual, cantCuotas)
    SELECT g.idGasto, gt.cuotaActual, gt.cantCuotas
    FROM #GastosTemp gt
    JOIN #Exp x ON x.idConsorcio = gt.idConsorcio AND x.fecha = gt.fechaEmision
    JOIN app.Tbl_Gasto g
      ON g.idConsorcio = gt.idConsorcio
     AND g.nroExpensa  = x.nroExpensa
     AND g.tipo        = 'Extraordinario'
     AND ISNULL(g.descripcion,'') = ISNULL(gt.descripcion,'')
    WHERE NOT EXISTS (
        SELECT 1 FROM app.Tbl_Gasto_Extraordinario ge WHERE ge.idGasto = g.idGasto
    );

    /* 5) Recalcular montos de las expensas afectadas */
    UPDATE e
       SET e.montoTotal = (
            SELECT ISNULL(SUM(g.importe),0)
            FROM app.Tbl_Gasto g
            WHERE g.idConsorcio = e.idConsorcio
              AND g.nroExpensa  = e.nroExpensa
       )
    FROM app.Tbl_Expensa e
    JOIN #Exp x ON x.idConsorcio = e.idConsorcio AND x.nroExpensa = e.nroExpensa;

    IF @Verbose = 1
    BEGIN
        PRINT 'Resumen de gastos extraordinarios:';
        SELECT g.idConsorcio, g.nroExpensa, g.descripcion, g.importe, ge.cuotaActual, ge.cantCuotas
        FROM app.Tbl_Gasto g
        JOIN app.Tbl_Gasto_Extraordinario ge ON ge.idGasto = g.idGasto
        WHERE g.tipo = 'Extraordinario'
        ORDER BY g.idConsorcio, g.nroExpensa, g.idGasto;
    END
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE app.Sp_RecalcularMoraEstadosCuenta_Todo
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg_pagos AS (
        SELECT
            p.idEstadoCuenta,
            SUM(p.monto) AS montoPagado,
            MAX(p.fecha) AS fechaUltimoPago
        FROM app.Tbl_Pago p
        WHERE p.idEstadoCuenta IS NOT NULL
        GROUP BY p.idEstadoCuenta
    )
    UPDATE ec
       SET
           ec.pagoRecibido = ISNULL(ap.montoPagado, 0),

           ec.deuda =
               CASE
                   WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0) THEN 0
                   ELSE calc.baseMes - ISNULL(ap.montoPagado, 0)
               END,

           ec.interesMora =
               CASE
                   WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0)
                        OR ap.montoPagado IS NULL THEN 0
                   WHEN ap.fechaUltimoPago <= ex.fechaVto1 THEN 0
                   WHEN ap.fechaUltimoPago > ex.fechaVto1
                        AND (ex.fechaVto2 IS NULL OR ap.fechaUltimoPago <= ex.fechaVto2)
                        THEN ROUND(0.02 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)
                   WHEN ex.fechaVto2 IS NOT NULL AND ap.fechaUltimoPago > ex.fechaVto2
                        THEN ROUND(0.05 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)
                   ELSE 0
               END,

           ec.totalAPagar =
               CASE
                   WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0) THEN 0
                   ELSE
                       (calc.baseMes - ISNULL(ap.montoPagado, 0))
                       +
                       CASE
                           WHEN ap.fechaUltimoPago <= ex.fechaVto1 THEN 0
                           WHEN ap.fechaUltimoPago > ex.fechaVto1
                                AND (ex.fechaVto2 IS NULL OR ap.fechaUltimoPago <= ex.fechaVto2)
                                THEN ROUND(0.02 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)
                           WHEN ex.fechaVto2 IS NOT NULL AND ap.fechaUltimoPago > ex.fechaVto2
                                THEN ROUND(0.05 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)
                           ELSE 0
                       END
               END
    FROM app.Tbl_EstadoCuenta ec
    LEFT JOIN agg_pagos ap
      ON ap.idEstadoCuenta = ec.idEstadoCuenta
    JOIN app.Tbl_Expensa ex
      ON ex.idConsorcio = ec.idConsorcio
     AND ex.nroExpensa  = ec.nroExpensa
    CROSS APPLY (
        SELECT baseMes =
            ISNULL(ec.expensasOrdinarias, 0) +
            ISNULL(ec.expensasExtraordinarias, 0)
    ) AS calc;
END;
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE reportes.Sp_ReporteEstadoFinanciero
    @Anio        INT,
    @IdConsorcio INT     = NULL,   -- NULL = todos
    @MesDesde    TINYINT = 1,      -- 1..12
    @MesHasta    TINYINT = 12,     -- 1..12
    @LogPath     NVARCHAR(4000) = NULL,
    @Verbose     BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'reportes.Sp_ReporteEstadoFinanciero';

    IF @MesDesde < 1 OR @MesDesde > 12
       OR @MesHasta < 1 OR @MesHasta > 12
       OR @MesDesde > @MesHasta
    BEGIN
        RAISERROR(N'Rango de meses inválido.', 16, 1);
        RETURN;
    END;

    IF @Verbose = 1
        EXEC reportes.Sp_LogReporte
             @Procedimiento, 'INFO',
             N'Inicio reporte estado financiero',
             NULL, NULL, @LogPath;

    ;WITH meses AS (
        SELECT DISTINCT
            e.idConsorcio,
            YEAR(e.fechaGeneracion)  AS Anio,
            MONTH(e.fechaGeneracion) AS Mes
        FROM app.Tbl_Expensa e
        WHERE YEAR(e.fechaGeneracion) = @Anio
          AND MONTH(e.fechaGeneracion) BETWEEN @MesDesde AND @MesHasta
          AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
    ),
    base AS (
        SELECT
            m.idConsorcio,
            m.Anio,
            m.Mes,
            DATEFROMPARTS(m.Anio, m.Mes, 1)                  AS FechaInicio,
            EOMONTH(DATEFROMPARTS(m.Anio, m.Mes, 1))         AS FechaFin
        FROM meses m
    ),
    ingresos AS (
        SELECT
            b.idConsorcio,
            b.Anio,
            b.Mes,
            -- pagos de expensas del MISMO mes
            SUM(CASE
                    WHEN e.fechaGeneracion >= b.FechaInicio
                     AND e.fechaGeneracion <= b.FechaFin
                    THEN p.monto ELSE 0
                END) AS IngresosEnTermino,
            -- pagos de expensas de meses ANTERIORES (saldo deudor)
            SUM(CASE
                    WHEN e.fechaGeneracion < b.FechaInicio
                    THEN p.monto ELSE 0
                END) AS IngresosAdeudadas,
            -- pagos de expensas de meses POSTERIORES (adelantadas)
            SUM(CASE
                    WHEN e.fechaGeneracion > b.FechaFin
                    THEN p.monto ELSE 0
                END) AS IngresosAdelantadas,
            -- total ingresos del mes (suma de todo)
            SUM(p.monto) AS IngresosTotal
        FROM base b
        LEFT JOIN app.Tbl_Pago p
          ON p.idConsorcio = b.idConsorcio
         AND p.fecha BETWEEN b.FechaInicio AND b.FechaFin
        LEFT JOIN app.Tbl_Expensa e
          ON e.nroExpensa   = p.nroExpensa
         AND e.idConsorcio  = p.idConsorcio
        GROUP BY
            b.idConsorcio, b.Anio, b.Mes
    ),
    egresos AS (
        SELECT
            b.idConsorcio,
            b.Anio,
            b.Mes,
            SUM(g.importe) AS EgresosMes
        FROM base b
        LEFT JOIN app.Tbl_Gasto g
          ON g.idConsorcio  = b.idConsorcio
         AND g.fechaEmision BETWEEN b.FechaInicio AND b.FechaFin
        GROUP BY
            b.idConsorcio, b.Anio, b.Mes
    ),
    combinado AS (
        SELECT
            b.idConsorcio,
            b.Anio,
            b.Mes,
            ISNULL(i.IngresosTotal,       0) AS IngresosTotal,
            ISNULL(i.IngresosEnTermino,   0) AS IngresosEnTermino,
            ISNULL(i.IngresosAdeudadas,   0) AS IngresosAdeudadas,
            ISNULL(i.IngresosAdelantadas, 0) AS IngresosAdelantadas,
            ISNULL(e.EgresosMes,          0) AS EgresosMes
        FROM base b
        LEFT JOIN ingresos i
               ON i.idConsorcio = b.idConsorcio
              AND i.Anio        = b.Anio
              AND i.Mes         = b.Mes
        LEFT JOIN egresos e
               ON e.idConsorcio = b.idConsorcio
              AND e.Anio        = b.Anio
              AND e.Mes         = b.Mes
    ),
    fin AS (
        SELECT
            c.idConsorcio,
            cs.nombre AS nombreConsorcio,
            c.Anio,
            c.Mes,
            c.IngresosTotal,
            c.IngresosEnTermino,
            c.IngresosAdeudadas,
            c.IngresosAdelantadas,
            c.EgresosMes,
            -- saldo acumulado = Σ (ingresos - egresos) hasta ese mes
            SUM(c.IngresosTotal - c.EgresosMes) OVER (
                PARTITION BY c.idConsorcio
                ORDER BY     c.Anio, c.Mes
            ) AS SaldoAcumulado
        FROM combinado c
        JOIN app.Tbl_Consorcio cs
          ON cs.idConsorcio = c.idConsorcio
    )
    SELECT
        f.idConsorcio,
        f.nombreConsorcio,
        f.Anio,
        f.Mes,
        -- saldo anterior = saldo acumulado del mes previo
        LAG(f.SaldoAcumulado, 1, 0) OVER (
            PARTITION BY f.idConsorcio
            ORDER BY     f.Anio, f.Mes
        ) AS SaldoAnterior,
        f.IngresosEnTermino,
        f.IngresosAdeudadas,
        f.IngresosAdelantadas,
        f.EgresosMes                  AS EgresosGastosMes,
        f.SaldoAcumulado              AS SaldoAlCierre
    FROM fin f
    ORDER BY
        f.idConsorcio, f.Anio, f.Mes;

    IF @Verbose = 1
        EXEC reportes.Sp_LogReporte
             @Procedimiento, 'INFO',
             N'Fin OK reporte estado financiero',
             NULL, NULL, @LogPath;
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE reportes.Sp_ReporteEstadoCuentasProrrateo
    @IdConsorcio INT     = NULL,
    @Anio        INT     = NULL,
    @Mes         TINYINT = NULL,
    @NroExpensa  INT     = NULL,
    @LogPath     NVARCHAR(4000) = NULL,
    @Verbose     BIT     = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'reportes.Sp_ReporteEstadoCuentasProrrateo';

    IF @Verbose = 1
        EXEC reportes.Sp_LogReporte
             @Procedimiento, 'INFO',
             N'Inicio reporte estado de cuentas',
             NULL, NULL, @LogPath;

    SELECT
        c.idConsorcio,
        c.nombre                 AS Consorcio,
        e.nroExpensa,
        e.fechaGeneracion,
        ec.nroUnidadFuncional    AS Uf,
        uf.porcentaje            AS Porcentaje,
        uf.piso                  AS Piso,
        uf.departamento          AS Depto,
        CASE WHEN ISNULL(uf.metrosCochera, 0) > 0 THEN 1 ELSE 0 END AS Cocheras,
        CASE WHEN ISNULL(uf.metrosBaulera, 0) > 0 THEN 1 ELSE 0 END AS Bauleras,
        COALESCE(
            p.apellido + ', ' + p.nombre,
            p.nombre,
            p.apellido
        )                        AS Propietario,
        ec.saldoAnterior         AS SaldoAnteriorAbonado,
        ec.pagoRecibido          AS PagosRecibidos,
        ec.deuda                 AS Deuda,
        ec.interesMora           AS InteresMora,
        ec.expensasOrdinarias    AS ExpensasOrdinarias,
        ec.expensasExtraordinarias AS ExpensasExtraordinarias,
        ec.totalAPagar           AS TotalAPagar
    FROM app.Tbl_EstadoCuenta ec
    JOIN app.Tbl_UnidadFuncional uf
      ON uf.idUnidadFuncional = ec.nroUnidadFuncional
    JOIN app.Tbl_Consorcio c
      ON c.idConsorcio = ec.idConsorcio
    JOIN app.Tbl_Expensa e
      ON e.nroExpensa  = ec.nroExpensa
     AND e.idConsorcio = ec.idConsorcio
    LEFT JOIN app.Tbl_Persona p
      ON p.CBU_CVU = uf.CBU_CVU
    WHERE (@IdConsorcio IS NULL OR c.idConsorcio = @IdConsorcio)
      AND (@NroExpensa IS NULL OR e.nroExpensa = @NroExpensa)
      AND (@Anio IS NULL OR YEAR(e.fechaGeneracion) = @Anio)
      AND (@Mes  IS NULL OR MONTH(e.fechaGeneracion) = @Mes)
    ORDER BY
        c.idConsorcio,
        e.fechaGeneracion,
        ec.nroUnidadFuncional;

    IF @Verbose = 1
        EXEC reportes.Sp_LogReporte
             @Procedimiento, 'INFO',
             N'Fin OK reporte estado de cuentas',
             NULL, NULL, @LogPath;
END
GO
-- //////////////////////////////////////////////////////////////////////
