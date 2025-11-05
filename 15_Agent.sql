USE Com5600G13;
GO
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;


/** ============================================================
   1. TABLA DE FERIADOS
============================================================ **/
IF OBJECT_ID(N'app.Tbl_Feriado', N'U') IS NOT NULL
    DROP TABLE app.Tbl_Feriado;
GO

CREATE TABLE app.Tbl_Feriado (
    fecha DATE NOT NULL PRIMARY KEY
);
GO

/* ============================================================
   2. PROCEDIMIENTO: CARGAR FERIADOS DESDE API
============================================================ */

CREATE OR ALTER PROCEDURE app.Sp_CargarFeriados
    @Anio INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE 
        @url   NVARCHAR(4000) = N'https://date.nager.at/api/v3/PublicHolidays/' 
                                + CONVERT(NVARCHAR(10), @Anio) + N'/AR',
        @file  NVARCHAR(260)  = N'C:\Temp\feriados_' + CONVERT(NVARCHAR(10), @Anio) + N'_nager.json',
        @cmd   NVARCHAR(4000),
        @json  NVARCHAR(MAX),
        @exists INT;

    -- Asegurar carpeta (opcional, por si no existe)
    EXEC xp_cmdshell 'if not exist C:\Temp mkdir C:\Temp', NO_OUTPUT;

    -- Limpiar archivo previo
    SET @cmd = N'del /Q "' + @file + N'"';
    EXEC xp_cmdshell @cmd, NO_OUTPUT;

    -- Descargar con curl; si no queda archivo, fallback a certutil
    SET @cmd = N'curl -s -L -H "Accept: application/json" -o "' + @file + N'" "' + @url + N'"';
    EXEC xp_cmdshell @cmd;

    DECLARE @fx TABLE (FileExists INT, IsDirectory INT, ParentExists INT);
    INSERT INTO @fx EXEC master..xp_fileexist @file;
    SELECT @exists = FileExists FROM @fx;

    IF ISNULL(@exists,0) = 0
    BEGIN
        DELETE FROM @fx;
        SET @cmd = N'certutil -urlcache -split -f "' + @url + N'" "' + @file + N'"';
        EXEC xp_cmdshell @cmd;

        INSERT INTO @fx EXEC master..xp_fileexist @file;
        SELECT @exists = FileExists FROM @fx;

        IF ISNULL(@exists,0) = 0
        BEGIN
            RAISERROR('No se logró descargar el JSON (ni con curl ni con certutil).', 16, 1);
            RETURN;
        END
    END

    CREATE TABLE #Raw(BulkColumn NVARCHAR(MAX));
    DECLARE @sql NVARCHAR(MAX) = N'
        INSERT INTO #Raw(BulkColumn)
        SELECT BulkColumn
        FROM OPENROWSET(
            BULK ''' + REPLACE(@file,'''','''''') + N''',
            SINGLE_CLOB,
            CODEPAGE = 65001
        ) AS J;';
    EXEC sp_executesql @sql;

    SELECT TOP 1 @json = BulkColumn FROM #Raw;

    IF (@json IS NULL OR LEN(@json)=0)
    BEGIN
        RAISERROR('El archivo se descargó pero vino vacío o no se pudo leer como UTF-8.', 16, 1);
        RETURN;
    END

    IF ISJSON(@json) <> 1
    BEGIN
        DECLARE @snippet NVARCHAR(200) = LEFT(@json, 200);
        RAISERROR('El contenido no parece JSON válido. Inicio: %s', 16, 1, @snippet);
        RETURN;
    END

    -- Insertar solo las fechas evitando duplicados
    ;WITH F AS (
        SELECT fecha = TRY_CONVERT(date, [date])
        FROM OPENJSON(@json)
        WITH ([date] NVARCHAR(20) '$.date')
    )
    INSERT INTO app.Tbl_Feriado(fecha)
    SELECT F.fecha
    FROM F
    WHERE F.fecha IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM app.Tbl_Feriado t WHERE t.fecha = F.fecha);
END;
GO

/* ============================================================
   3. FUNCIÓN: ES DÍA HÁBIL
============================================================ */
CREATE OR ALTER FUNCTION app.fn_EsDiaHabil(@Fecha DATE)
RETURNS BIT
AS
BEGIN
    IF DATEPART(WEEKDAY, @Fecha) IN (1,7)
        RETURN 0;
    IF EXISTS (SELECT 1 FROM app.Tbl_Feriado WHERE fecha = @Fecha)
        RETURN 0;
    RETURN 1;
END;
GO

/* ============================================================
   4. FUNCIÓN: OBTENER 5° DÍA HÁBIL DEL MES
============================================================ */
CREATE OR ALTER FUNCTION app.fn_ObtenerQuintoDiaHabil(@Mes DATE)
RETURNS DATE
AS
BEGIN
    DECLARE @Dia DATE = DATEFROMPARTS(YEAR(@Mes), MONTH(@Mes), 1);
    DECLARE @Contador INT = 0;

    WHILE @Contador < 5
    BEGIN
        IF app.fn_EsDiaHabil(@Dia) = 1
            SET @Contador += 1;
        IF @Contador < 5
            SET @Dia = DATEADD(DAY, 1, @Dia);
    END

    RETURN @Dia;
END;
GO

/* ============================================================
   5. PROCEDIMIENTO: VERIFICAR Y GENERAR EXPENSAS
============================================================ */
CREATE OR ALTER PROCEDURE app.Sp_VerificarYGenerarExpensas
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Hoy DATE = GETDATE();
    DECLARE @QuintoDiaHabil DATE = app.fn_ObtenerQuintoDiaHabil(@Hoy);

    -- Cargar feriados si es enero y no están cargados
    IF MONTH(@Hoy) = 1 AND NOT EXISTS (SELECT 1 FROM app.Tbl_Feriado WHERE YEAR(fecha) = YEAR(@Hoy))
    BEGIN
        EXEC app.Sp_CargarFeriados @Anio = 2025;
    END

    -- Generar expensas solo si hoy es el 5° día hábil
    IF @Hoy = @QuintoDiaHabil
    BEGIN
        PRINT 'Generando expensas - Quinto día hábil: ' + CONVERT(VARCHAR, @Hoy, 103);

        INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
        SELECT 
            idConsorcio,
            @Hoy,
            DATEADD(DAY, 10, @Hoy),
            DATEADD(DAY, 20, @Hoy),
            10000.00 -- monto base temporal
        FROM app.Tbl_Consorcio;

        EXEC app.Sp_SimularEnvioExpensas;
    END
    ELSE
        PRINT 'Hoy no es quinto día hábil. Próximo: ' + CONVERT(VARCHAR, @QuintoDiaHabil, 103);
END;
GO

/* ============================================================
   6. PROCEDIMIENTO: SIMULAR ENVÍO DE EXPENSAS
============================================================ */
CREATE OR ALTER PROCEDURE app.Sp_SimularEnvioExpensas
    @NroExpensa INT = NULL
AS
BEGIN
    IF @NroExpensa IS NULL
        SELECT TOP 1 @NroExpensa = nroExpensa FROM app.Tbl_Expensa ORDER BY nroExpensa DESC;

    PRINT 'Enviando expensa ' + CAST(@NroExpensa AS VARCHAR) + ' a:';

    SELECT 
        p.nombre + ' ' + p.apellido AS persona,
        CASE 
            WHEN p.email IS NOT NULL THEN 'EMAIL: ' + p.email
            WHEN p.telefono IS NOT NULL THEN 'WHATSAPP: ' + p.telefono
            ELSE 'IMPRESO'
        END AS medio,
        CASE WHEN ufp.esInquilino = 1 THEN 'Inquilino' ELSE 'Propietario' END AS tipo
    FROM app.Tbl_Expensa e
    JOIN app.Tbl_UnidadFuncional uf ON uf.idConsorcio = e.idConsorcio
    JOIN app.Tbl_UFPersona ufp ON ufp.idConsorcio = uf.idConsorcio
    JOIN app.Tbl_Persona p ON p.idPersona = ufp.idPersona
    WHERE e.nroExpensa = @NroExpensa
      AND (ufp.fechaFin IS NULL OR ufp.fechaFin >= e.fechaGeneracion);
END;
GO

/* ============================================================
   7. CARGAR FERIADOS INICIALES
============================================================ */
EXEC app.Sp_CargarFeriados @Anio = 2025;
GO

/* ============================================================
   8. CONFIGURAR JOBS EN SQL SERVER AGENT (SI ESTÁ DISPONIBLE)
============================================================ */
USE msdb;
GO

-- Eliminar relaciones entre schedules y jobs duplicados
DELETE FROM msdb.dbo.sysjobschedules
WHERE schedule_id IN (
    SELECT schedule_id FROM msdb.dbo.sysschedules WHERE name IN ('Diario_8AM', 'AlInicioAgent')
);
GO

-- Eliminar schedules duplicados
DELETE FROM msdb.dbo.sysschedules
WHERE name IN ('Diario_8AM', 'AlInicioAgent');
GO

-- Eliminar jobs si existen
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'GenerarExpensas_VerificacionDiaria')
    EXEC sp_delete_job @job_name = N'GenerarExpensas_VerificacionDiaria';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'CargarFeriados_InicioSistema')
    EXEC sp_delete_job @job_name = N'CargarFeriados_InicioSistema';
GO

/* ===== Job 1: Verificación diaria de expensas ===== */
EXEC dbo.sp_add_job
    @job_name = N'GenerarExpensas_VerificacionDiaria',
    @enabled = 1,
    @description = N'Verifica diariamente si es el quinto día hábil para generar expensas.';

EXEC sp_add_jobstep
    @job_name = N'GenerarExpensas_VerificacionDiaria',
    @step_name = N'VerificarYGenerar',
    @subsystem = N'TSQL',
    @command = N'EXEC Com5600G13.app.Sp_VerificarYGenerarExpensas;',
    @database_name = N'Com5600G13';

EXEC sp_add_schedule
    @schedule_name = N'Diario_8AM',
    @freq_type = 4, -- Diario
    @freq_interval = 1,
    @active_start_time = 80000; -- 08:00:00

EXEC sp_attach_schedule
    @job_name = N'GenerarExpensas_VerificacionDiaria',
    @schedule_name = N'Diario_8AM';

EXEC sp_add_jobserver
    @job_name = N'GenerarExpensas_VerificacionDiaria';
GO

/* ===== Job 2: Carga de feriados al iniciar el servicio ===== */
EXEC dbo.sp_add_job
    @job_name = N'CargarFeriados_InicioSistema',
    @enabled = 1,
    @description = N'Carga feriados al iniciar el SQL Server Agent.';

EXEC sp_add_jobstep
    @job_name = N'CargarFeriados_InicioSistema',
    @step_name = N'CargarFeriados',
    @subsystem = N'TSQL',
    @command = N'EXEC Com5600G13.app.Sp_CargarFeriados;',
    @database_name = N'Com5600G13';

EXEC sp_add_schedule
    @schedule_name = N'AlInicioAgent',
    @freq_type = 64;

EXEC sp_attach_schedule
    @job_name = N'CargarFeriados_InicioSistema',
    @schedule_name = N'AlInicioAgent';

EXEC sp_add_jobserver
    @job_name = N'CargarFeriados_InicioSistema';
GO


SELECT 
    @@VERSION AS Version,
    SERVERPROPERTY('Edition') AS Edition,
    SERVERPROPERTY('ProductVersion') AS ProductVersion;