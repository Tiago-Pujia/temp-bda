USE Com5600G13;
GO

-- Función: limpia espacios a los costados y recorta a largo máximo.
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

-- Función: convierte texto a DECIMAL(10,2), acepta coma o punto.
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

CREATE OR ALTER FUNCTION importacion.fn_ParseImporteFlexible (@s NVARCHAR(100))
RETURNS DECIMAL(18,2)
AS
BEGIN
    -- 0) Atajos
    IF @s IS NULL OR LTRIM(RTRIM(@s)) = N'' 
        RETURN NULL;

    DECLARE @t NVARCHAR(100);

    -- 1) Normalizar: sacar NBSP, 'ARS', '$', espacios y tabs
    SET @t = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@s, CHAR(160), ' '), N'ARS', N''), N'$', N''), N' ', N''), CHAR(9), N'');

    -- 2) Negativos tipo (123,45) => -123,45
    IF LEFT(@t,1) = N'(' AND RIGHT(@t,1) = N')'
        SET @t = N'-' + SUBSTRING(@t, 2, LEN(@t)-2);

    DECLARE @res DECIMAL(18,2);

    -- 3) Estilo US: quitar separadores de miles (,) y castear
    SET @res = TRY_CONVERT(DECIMAL(18,2), REPLACE(@t, N',', N''));
    IF @res IS NOT NULL RETURN @res;

    -- 4) Estilo EU: quitar miles (.) y cambiar decimal (,) -> (.)
    SET @res = TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(@t, N'.', N''), N',', N'.'));
    IF @res IS NOT NULL RETURN @res;

    -- 5) Fallback:
    --    a) Dejar solo 0-9 . , - 
    --    b) Decidir separador decimal como el último (.,) que aparezca
    DECLARE @u NVARCHAR(100) = N'';
    DECLARE @i INT = 1, @c NCHAR(1);

    WHILE @i <= LEN(@t)
    BEGIN
        SET @c = SUBSTRING(@t, @i, 1);
        IF @c LIKE N'[0-9]' OR @c IN (N'.', N',', N'-')
            SET @u = @u + @c;
        SET @i += 1;
    END

    -- Posición desde el final (el último que aparezca)
    DECLARE @pDot INT = NULLIF(CHARINDEX(N'.', REVERSE(@u)), 0);
    DECLARE @pCom INT = NULLIF(CHARINDEX(N',', REVERSE(@u)), 0);
    DECLARE @sep  NCHAR(1) =
        CASE WHEN @pDot IS NOT NULL AND (@pCom IS NULL OR @pDot < @pCom) THEN N'.'
             WHEN @pCom IS NOT NULL THEN N',' 
             ELSE N'.' END;

    IF @sep = N'.'
        SET @u = REPLACE(@u, N',', N'');               -- miles = ,  -> eliminar
    ELSE
        SET @u = REPLACE(REPLACE(@u, N'.', N''), N',', N'.'); -- miles = . ; decimal = , -> .

    RETURN TRY_CONVERT(DECIMAL(18,2), @u);
END
GO

CREATE OR ALTER FUNCTION api.fn_ObtenerCotizacionActual(@TipoDolar VARCHAR(50) = 'blue')
RETURNS DECIMAL(10,2)
AS
BEGIN
    DECLARE @cot DECIMAL(10,2) = NULL;

    SELECT TOP (1) @cot = valorVenta
    FROM api.Tbl_CotizacionDolar
    WHERE tipoDolar = @TipoDolar
    ORDER BY fechaConsulta DESC;

    -- si no hay dato reciente, devolvé 0 (que el caller decida fallback)
    RETURN ISNULL(@cot, 0);
END
GO

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

CREATE OR ALTER FUNCTION importacion.fn_EmailValido
(
    @Email NVARCHAR(320)
)
RETURNS BIT
AS
BEGIN
    -- Normalización mínima (trim y NBSP->espacio)
    DECLARE @e NVARCHAR(320) = LTRIM(RTRIM(ISNULL(@Email, N'')));
    SET @e = REPLACE(@e, NCHAR(160), N' ');

    -- Vacío
    IF @e = N'' RETURN 0;

    -- No espacios ni saltos
    IF PATINDEX(N'%[' + NCHAR(9) + NCHAR(10) + NCHAR(13) + N' ]%', @e) > 0 RETURN 0;

    -- Punto no primero/último y sin consecutivos
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

    -- Local-part: sólo A-Za-z0-9._+-
    IF PATINDEX(N'%[^-0-9A-Za-z._+]%', @local COLLATE Latin1_General_BIN2) > 0 RETURN 0;
    IF LEFT(@local,1) = N'.' OR RIGHT(@local,1) = N'.' RETURN 0;
    IF CHARINDEX(N'..', @local) > 0 RETURN 0;

    -- Dominio: debe tener al menos un punto
    IF CHARINDEX(N'.', @domain) = 0 RETURN 0;

    -- Dominio: sólo A-Za-z0-9.-
    IF PATINDEX(N'%[^-0-9A-Za-z.]%', @domain COLLATE Latin1_General_BIN2) > 0 RETURN 0;

    -- Dominio: no empieza/termina con . o -
    IF LEFT(@domain,1) IN (N'.', N'-') OR RIGHT(@domain,1) IN (N'.', N'-') RETURN 0;

    -- Dominio: sin .. ni .- ni -.
    IF CHARINDEX(N'..', @domain) > 0 OR CHARINDEX(N'.-', @domain) > 0 OR CHARINDEX(N'-.', @domain) > 0 RETURN 0;

    -- Cada etiqueta <= 63 y sin guión al inicio/fin
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

    -- TLD: sólo letras, largo 2–24
    DECLARE @lastDot INT = LEN(@domain) - CHARINDEX(N'.', REVERSE(@domain)) + 1;
    DECLARE @tld NVARCHAR(24) = SUBSTRING(@domain, @lastDot + 1, LEN(@domain) - @lastDot);
    IF LEN(@tld) < 2 OR LEN(@tld) > 24 RETURN 0;
    IF PATINDEX(N'%[^A-Za-z]%', @tld COLLATE Latin1_General_BIN2) > 0 RETURN 0;

    RETURN 1;
END
GO

CREATE OR ALTER FUNCTION seguridad.fn_EncriptarTexto(@texto NVARCHAR(4000))
RETURNS VARBINARY(512)
AS
BEGIN
    IF @texto IS NULL RETURN NULL;

    RETURN ENCRYPTBYPASSPHRASE(N'Consorcio-2025-ClaveSecreta', @texto);
END;
GO

CREATE OR ALTER FUNCTION seguridad.fn_DesencriptarTexto(@dato VARBINARY(512))
RETURNS NVARCHAR(4000)
AS
BEGIN
    IF @dato IS NULL RETURN NULL;

    RETURN CONVERT(NVARCHAR(4000),
                   DECRYPTBYPASSPHRASE(N'Consorcio-2025-ClaveSecreta', @dato));
END;
GO