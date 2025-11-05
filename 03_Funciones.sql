USE Com5600G13;
GO

/** Funcion: limpia espacios a los costados y recorta a largo maximo. **/
CREATE OR ALTER FUNCTION importacion.fn_LimpiarTexto
(
    @texto   NVARCHAR(MAX),
    @largo   INT
)
RETURNS VARCHAR(8000)
AS
BEGIN
    DECLARE @t VARCHAR(8000);
    SET @t = CONVERT(VARCHAR(8000), LTRIM(RTRIM(ISNULL(@texto, N'')))) COLLATE DATABASE_DEFAULT;

    IF @largo IS NOT NULL AND @largo > 0 AND LEN(@t) > @largo
        SET @t = LEFT(@t, @largo);

    IF @t = '' SET @t = NULL;
    RETURN @t;
END
GO

/** Convierte texto a DECIMAL(10,2), acepta coma o punto. **/
CREATE OR ALTER FUNCTION importacion.fn_A_Decimal
(
    @texto NVARCHAR(200)
)
RETURNS DECIMAL(10,2)
AS
BEGIN
    IF @texto IS NULL RETURN NULL;

    DECLARE @t NVARCHAR(200) = LTRIM(RTRIM(@texto));
    IF @t = N'' RETURN NULL;

    -- Saco espacios y NBSP, y uso punto como separador decimal
    SET @t = REPLACE(@t, NCHAR(160), N'');
    SET @t = REPLACE(@t, N' ', N'');
    SET @t = REPLACE(@t, N',', N'.');

    RETURN TRY_CONVERT(DECIMAL(10,2), @t);
END
GO

/** Devuelve el importe en el formato correcto **/
CREATE OR ALTER FUNCTION importacion.fn_ParseImporteFlexible (@s NVARCHAR(100))
RETURNS DECIMAL(18,2)
AS
BEGIN
    IF @s IS NULL OR LTRIM(RTRIM(@s)) = N'' RETURN NULL;

    -- 1) Normalizar: quitar NBSP, ARS, $, espacios y tabs
    DECLARE @t NVARCHAR(100) =
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@s, CHAR(160), ' ')
             , N'ARS', N''), N'$', N''), N' ', N''), CHAR(9), N'');

    -- 2) Negativos tipo (123,45) => -123,45
    IF LEFT(@t,1)=N'(' AND RIGHT(@t,1)=N')'
        SET @t = N'-' + SUBSTRING(@t,2,LEN(@t)-2);

    -- 3) Dejar solo dígitos, separadores y signo
    DECLARE @u NVARCHAR(100) = N'';
    DECLARE @i INT = 1, @c NCHAR(1);
    WHILE @i <= LEN(@t)
    BEGIN
        SET @c = SUBSTRING(@t,@i,1);
        IF (@c LIKE N'[0-9]') OR (@c IN (N'.',N',',N'-'))
            SET @u += @c;
        SET @i += 1;
    END
    IF @u = N'' RETURN NULL;

    -- 4) Manejo de signo
    DECLARE @sign NVARCHAR(1) = CASE WHEN LEFT(@u,1)='-' THEN '-' ELSE '' END;
    IF @sign='-' SET @u = SUBSTRING(@u,2,LEN(@u));
    SET @u = REPLACE(@u, N'-', N''); -- quitar guiones restantes

    -- 5) Elegir SIEMPRE el último separador (.,) como decimal
    DECLARE @pDot INT = NULLIF(CHARINDEX(N'.', REVERSE(@u)), 0);
    DECLARE @pCom INT = NULLIF(CHARINDEX(N',', REVERSE(@u)), 0);

    -- Si no hay separador: quitar todos y castear
    IF @pDot IS NULL AND @pCom IS NULL
    BEGIN
        SET @u = REPLACE(REPLACE(@u, N'.', N''), N',', N'');
        RETURN TRY_CONVERT(DECIMAL(18,2), @sign + @u);
    END

    -- Separador = el que esté más a la derecha en la cadena original
    DECLARE @sep NCHAR(1) =
        CASE WHEN @pDot IS NOT NULL AND (@pCom IS NULL OR @pDot < @pCom) THEN N'.' ELSE N',' END;

    -- Posición del separador en la cadena original (desde el inicio)
    DECLARE @pos INT = LEN(@u) - CASE WHEN @sep='.' THEN @pDot ELSE @pCom END + 1;

    DECLARE @left  NVARCHAR(100) = SUBSTRING(@u, 1, @pos-1);
    DECLARE @right NVARCHAR(100) = SUBSTRING(@u, @pos+1, LEN(@u));

    -- Quitar miles en ambos lados
    SET @left  = REPLACE(REPLACE(@left,  N'.', N''), N',', N'');
    SET @right = REPLACE(REPLACE(@right, N'.', N''), N',', N'');

    -- Armar número normalizado con punto decimal
    DECLARE @normalized NVARCHAR(202) =
        @sign + CASE WHEN @left = '' THEN '0' ELSE @left END + N'.' + @right;

    RETURN TRY_CONVERT(DECIMAL(18,2), @normalized);
END
GO

/** Obtiene la cotización de Tbl_CotizacionDolar **/
CREATE OR ALTER FUNCTION api.fn_ObtenerCotizacionActual(@TipoDolar VARCHAR(50) = 'blue')
RETURNS DECIMAL(10,2)
AS
BEGIN
    DECLARE @cot DECIMAL(10,2) = NULL;

    SELECT TOP (1) @cot = valorVenta
    FROM api.Tbl_CotizacionDolar
    WHERE tipoDolar = @TipoDolar
    ORDER BY fechaConsulta DESC;

    -- si no hay dato reciente, devolv� 0 (que el caller decida fallback)
    RETURN ISNULL(@cot, 0);
END
GO

/** Transforma los pesos a dolares **/
CREATE OR ALTER FUNCTION api.fn_PesosADolares(
    @Monto DECIMAL(18,2),
    @TipoDolar VARCHAR(50) = 'blue'
)
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @cot DECIMAL(10,2) = api.fn_ObtenerCotizacionActual(@TipoDolar);
    RETURN CASE WHEN @cot > 0 THEN @Monto / @cot ELSE NULL END;
END
GO

/** Verifica que un email es valido **/
CREATE OR ALTER FUNCTION importacion.fn_EmailValido
(
    @Email NVARCHAR(320)
)
RETURNS BIT
AS
BEGIN
    -- Normalizaci�n m�nima (trim y NBSP->espacio)
    DECLARE @e NVARCHAR(320) = LTRIM(RTRIM(ISNULL(@Email, N'')));
    SET @e = REPLACE(@e, NCHAR(160), N' ');

    -- Vac�o
    IF @e = N'' RETURN 0;

    -- No espacios ni saltos
    IF PATINDEX(N'%[' + NCHAR(9) + NCHAR(10) + NCHAR(13) + N' ]%', @e) > 0 RETURN 0;

    -- Punto no primero/�ltimo y sin consecutivos
    IF LEFT(@e,1) = N'.' OR RIGHT(@e,1) = N'.' RETURN 0;
    IF CHARINDEX(N'..', @e) > 0 RETURN 0;

    -- Exactamente un @
    DECLARE @at INT = CHARINDEX(N'@', @e);
    IF @at = 0 OR CHARINDEX(N'@', @e, @at + 1) > 0 RETURN 0;

    -- Longitud total <= 254 (RFC)
    IF LEN(@e) > 254 RETURN 0;

    -- Partes
    DECLARE @local  NVARCHAR(320) = SUBSTRING(@e, 1, @at - 1);
    DECLARE @domain NVARCHAR(320) = SUBSTRING(@e, @at + 1, LEN(@e) - @at);

    -- Longitudes
    IF LEN(@local)  < 1 OR LEN(@local)  > 64  RETURN 0;
    IF LEN(@domain) < 1 OR LEN(@domain) > 255 RETURN 0;

    -- Local-part: s�lo A-Za-z0-9._+-
    IF PATINDEX(N'%[^-0-9A-Za-z._+]%', @local COLLATE Latin1_General_BIN2) > 0 RETURN 0;
    IF LEFT(@local,1) = N'.' OR RIGHT(@local,1) = N'.' RETURN 0;
    IF CHARINDEX(N'..', @local) > 0 RETURN 0;

    -- Dominio: debe tener al menos un punto
    IF CHARINDEX(N'.', @domain) = 0 RETURN 0;

    -- Dominio: s�lo A-Za-z0-9.-
    IF PATINDEX(N'%[^-0-9A-Za-z.]%', @domain COLLATE Latin1_General_BIN2) > 0 RETURN 0;

    -- Dominio: no empieza/termina con . o -
    IF LEFT(@domain,1) IN (N'.', N'-') OR RIGHT(@domain,1) IN (N'.', N'-') RETURN 0;

    -- Dominio: sin .. ni .- ni -.
    IF CHARINDEX(N'..', @domain) > 0 OR CHARINDEX(N'.-', @domain) > 0 OR CHARINDEX(N'-.', @domain) > 0 RETURN 0;

    -- Cada etiqueta <= 63 y sin gui�n al inicio/fin
    DECLARE @pos INT = 1, @next INT, @label NVARCHAR(63);
    WHILE @pos <= LEN(@domain) + 1
    BEGIN
        SET @next = CHARINDEX(N'.', @domain, @pos);
        IF @next = 0 SET @next = LEN(@domain) + 1;

        SET @label = SUBSTRING(@domain, @pos, @next - @pos);
        IF LEN(@label) < 1 OR LEN(@label) > 63 RETURN 0;
        IF LEFT(@label,1) = N'-' OR RIGHT(@label,1) = N'-' RETURN 0;

        SET @pos = @next + 1;
    END

    -- TLD: s�lo letras, largo 2�24
    DECLARE @lastDot INT = LEN(@domain) - CHARINDEX(N'.', REVERSE(@domain)) + 1;
    DECLARE @tld NVARCHAR(24) = SUBSTRING(@domain, @lastDot + 1, LEN(@domain) - @lastDot);
    IF LEN(@tld) < 2 OR LEN(@tld) > 24 RETURN 0;
    IF PATINDEX(N'%[^A-Za-z]%', @tld COLLATE Latin1_General_BIN2) > 0 RETURN 0;

    RETURN 1;
END
GO

/** Normalizar email **/
CREATE OR ALTER FUNCTION importacion.fn_NormalizarEmail
(
    @Email NVARCHAR(320)
)
RETURNS NVARCHAR(320)
AS
BEGIN
    DECLARE @e NVARCHAR(320) = LTRIM(RTRIM(ISNULL(@Email, N'')));

    -- NBSP -> espacio
    SET @e = REPLACE(@e, NCHAR(160), N' ');

    -- Todo a minúsculas
    SET @e = LOWER(@e);

    -- Sacar tabs y saltos (dejar solo espacios comunes)
    SET @e = REPLACE(@e, CHAR(9),  N'');
    SET @e = REPLACE(@e, CHAR(10), N'');
    SET @e = REPLACE(@e, CHAR(13), N'');

    -- Reemplazar comas y punto y coma por punto (gmail,com -> gmail.com)
    SET @e = REPLACE(@e, N',', N'.');
    SET @e = REPLACE(@e, N';', N'.');

    -- Quitar espacios alrededor del @ ( "pepe @ gmail.com" -> "pepe@gmail.com" )
    SET @e = REPLACE(@e, N' @ ', N'@');
    SET @e = REPLACE(@e, N' @',  N'@');
    SET @e = REPLACE(@e, N'@ ',  N'@');

    -- Quitar espacios en el resto (pepe gmail.com -> pepegmail.com, después reparamos dominios típicos)
    SET @e = REPLACE(@e, N' ', N'');

    ----------------------------------------------------------------
    -- Correcciones de dominios típicos mal escritos
    ----------------------------------------------------------------
    -- gmail com / hotmail com / outlook com / yahoo com -> .com
    SET @e = REPLACE(@e, N'gmailcom',   N'gmail.com');
    SET @e = REPLACE(@e, N'hotmailcom', N'hotmail.com');
    SET @e = REPLACE(@e, N'outlookcom', N'outlook.com');
    SET @e = REPLACE(@e, N'yahoocom',   N'yahoo.com');
    SET @e = REPLACE(@e, N'livecom',    N'live.com');

    -- Variantes con "con" o "vom" (errores de tipeo comunes)
    SET @e = REPLACE(@e, N'gmailcon',   N'gmail.com');
    SET @e = REPLACE(@e, N'gmailvom',   N'gmail.com');

    -- gmail.com ar -> gmail.com.ar
    SET @e = REPLACE(@e, N'gmail.comar', N'gmail.com.ar');
    SET @e = REPLACE(@e, N'hotmail.comar', N'hotmail.com.ar');
    SET @e = REPLACE(@e, N'outlook.comar', N'outlook.com.ar');

    -- Variantes " arroba " / "(at)" por si aparecen
    SET @e = REPLACE(@e, N'(at)', N'@');
    SET @e = REPLACE(@e, N' arroba ', N'@');
    SET @e = REPLACE(@e, N' arroba',  N'@');
    SET @e = REPLACE(@e, N'arroba ',  N'@');

    RETURN LTRIM(RTRIM(@e));
END;
GO

/** Encripta un texto y retorna un alfanumerico **/
CREATE OR ALTER FUNCTION seguridad.fn_EncriptarTexto(@texto NVARCHAR(4000))
RETURNS VARBINARY(512)
AS
BEGIN
    RETURN
        CASE 
            WHEN @texto IS NULL THEN NULL
            ELSE CONVERT(VARBINARY(512), @texto)
        END;
END;
GO

/**Descripta un alfanumerico y retorna un texto  **/
CREATE OR ALTER FUNCTION seguridad.fn_DesencriptarTexto(@dato VARBINARY(512))
RETURNS NVARCHAR(4000)
AS
BEGIN
    IF @dato IS NULL RETURN NULL;

    RETURN CONVERT(NVARCHAR(4000), DECRYPTBYPASSPHRASE(N'Consorcio-2025-ClaveSecreta', @dato));
END;
GO