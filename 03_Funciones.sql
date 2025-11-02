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