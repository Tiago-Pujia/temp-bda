USE Com5600G13;
GO

CREATE OR ALTER PROCEDURE app.ObtenerRecaudacionPorMesYDepartamento
    @idConsorcio INT = NULL,
    @anio INT = NULL,
    @mesInicio INT = 1,
    @mesFin INT = 12
AS
BEGIN
    SET NOCOUNT ON;

    -- Defaults
    IF @anio IS NULL SET @anio = YEAR(GETDATE());
    IF @mesInicio < 1 OR @mesInicio > 12 SET @mesInicio = 1;
    IF @mesFin    < 1 OR @mesFin    > 12 SET @mesFin    = 12;

    IF @mesInicio > @mesFin
    BEGIN
        DECLARE @temp INT = @mesInicio;
        SET @mesInicio = @mesFin;
        SET @mesFin = @temp;
    END;

    ;WITH Meses AS (
        SELECT numero, nombre
        FROM (VALUES 
            (1,'Enero'), (2,'Febrero'), (3,'Marzo'), (4,'Abril'),
            (5,'Mayo'), (6,'Junio'), (7,'Julio'), (8,'Agosto'),
            (9,'Septiembre'), (10,'Octubre'), (11,'Noviembre'), (12,'Diciembre')
        ) AS M(numero,nombre)
        WHERE numero BETWEEN @mesInicio AND @mesFin
    ),
    RecaudacionBase AS (
        SELECT 
            UF.idUnidadFuncional,
            UF.departamento,
            MONTH(P.fecha) AS mes,
            SUM(P.monto)   AS monto
        FROM app.Tbl_UnidadFuncional UF
        INNER JOIN app.Tbl_Consorcio C
            ON UF.idConsorcio = C.idConsorcio
        LEFT JOIN app.Tbl_EstadoCuenta EC
            ON UF.idUnidadFuncional = EC.nroUnidadFuncional
           AND UF.idConsorcio       = EC.idConsorcio
        LEFT JOIN app.Tbl_Pago P
            ON EC.idEstadoCuenta     = P.idEstadoCuenta
           AND EC.nroUnidadFuncional = P.nroUnidadFuncional
           AND EC.idConsorcio        = P.idConsorcio
           AND YEAR(P.fecha)         = @anio   -- filtro de año en el JOIN
        WHERE (@idConsorcio IS NULL OR C.idConsorcio = @idConsorcio)
        GROUP BY UF.idUnidadFuncional, UF.departamento, MONTH(P.fecha)
    ),
    RecaudacionPivot AS (
        SELECT 
            idUnidadFuncional,
            departamento,
            ISNULL([1],0)  AS Enero,
            ISNULL([2],0)  AS Febrero,
            ISNULL([3],0)  AS Marzo,
            ISNULL([4],0)  AS Abril,
            ISNULL([5],0)  AS Mayo,
            ISNULL([6],0)  AS Junio,
            ISNULL([7],0)  AS Julio,
            ISNULL([8],0)  AS Agosto,
            ISNULL([9],0)  AS Septiembre,
            ISNULL([10],0) AS Octubre,
            ISNULL([11],0) AS Noviembre,
            ISNULL([12],0) AS Diciembre
        FROM RecaudacionBase
        PIVOT (
            SUM(monto)
            FOR mes IN ([1],[2],[3],[4],[5],[6],[7],[8],[9],[10],[11],[12])
        ) AS p
    )
    SELECT
        (
            SELECT 
                RP.departamento AS '@Departamento',
                (
                    SELECT 
                        M.nombre AS '@Mes',
                        CASE M.numero
                            WHEN 1  THEN RP.Enero
                            WHEN 2  THEN RP.Febrero
                            WHEN 3  THEN RP.Marzo
                            WHEN 4  THEN RP.Abril
                            WHEN 5  THEN RP.Mayo
                            WHEN 6  THEN RP.Junio
                            WHEN 7  THEN RP.Julio
                            WHEN 8  THEN RP.Agosto
                            WHEN 9  THEN RP.Septiembre
                            WHEN 10 THEN RP.Octubre
                            WHEN 11 THEN RP.Noviembre
                            WHEN 12 THEN RP.Diciembre
                        END AS '@Monto'
                    FROM Meses M
                    FOR XML PATH('Mes'), TYPE
                )
            FROM RecaudacionPivot RP
            ORDER BY RP.departamento
            FOR XML PATH('Departamento'), TYPE
        ) AS ResultadoXML  -- ? alias del subselect, no después de FOR XML de arriba
        ;
END
GO

EXEC app.ObtenerRecaudacionPorMesYDepartamento;
