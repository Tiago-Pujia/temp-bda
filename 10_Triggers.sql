USE Com5600G13;
GO

-- PERSONA
CREATE OR ALTER TRIGGER app.trg_Tbl_Persona_Cifrado
ON app.Tbl_Persona
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE p
    SET dniCifrado       = seguridad.fn_EncriptarTexto(CONVERT(NVARCHAR(50), p.dni)),
        emailCifrado     = seguridad.fn_EncriptarTexto(p.email),
        telefonoCifrado  = seguridad.fn_EncriptarTexto(p.telefono),
        CBU_CVU_Cifrado  = seguridad.fn_EncriptarTexto(p.CBU_CVU)
    FROM app.Tbl_Persona p
    INNER JOIN inserted i
        ON i.idPersona = p.idPersona;
END;
GO

-- UNIDAD FUNCIONAL
CREATE OR ALTER TRIGGER app.trg_Tbl_UnidadFuncional_Cifrado
ON app.Tbl_UnidadFuncional
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE uf
    SET CBU_CVU_Cifrado = seguridad.fn_EncriptarTexto(uf.CBU_CVU)
    FROM app.Tbl_UnidadFuncional uf
    INNER JOIN inserted i
        ON i.idUnidadFuncional = uf.idUnidadFuncional;
END;
GO

-- PAGO
CREATE OR ALTER TRIGGER app.trg_Tbl_Pago_Cifrado
ON app.Tbl_Pago
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE pa
    SET CBU_CVU_Cifrado = seguridad.fn_EncriptarTexto(pa.CBU_CVU)
    FROM app.Tbl_Pago pa
    INNER JOIN inserted i
        ON i.idPago = pa.idPago;
END;
GO

CREATE OR ALTER TRIGGER app.tr_Tbl_Pago_RecalcularMora
ON app.Tbl_Pago
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    /* 1) Estados de cuenta afectados por inserciones / updates / deletes */
    ;WITH afectados AS (
        SELECT idEstadoCuenta
        FROM inserted
        WHERE idEstadoCuenta IS NOT NULL
        UNION
        SELECT idEstadoCuenta
        FROM deleted
        WHERE idEstadoCuenta IS NOT NULL
    ),
    agg_pagos AS (
        SELECT
            p.idEstadoCuenta,
            SUM(p.monto) AS montoPagado,
            MAX(p.fecha) AS fechaUltimoPago
        FROM app.Tbl_Pago p
        JOIN afectados a
          ON a.idEstadoCuenta = p.idEstadoCuenta
        GROUP BY p.idEstadoCuenta
    )
    UPDATE ec
       SET
           -- 1) Total pagado
           ec.pagoRecibido = ISNULL(ap.montoPagado, 0),

           -- 2) Deuda = baseMes - pagos (no negativa)
           ec.deuda =
               CASE
                   WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0) THEN 0
                   ELSE calc.baseMes - ISNULL(ap.montoPagado, 0)
               END,

           -- 3) Interés por mora
           ec.interesMora =
               CASE
                   -- Si ya cubrió todo el mes o no hay pagos, no calculo mora
                   WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0)
                        OR ap.montoPagado IS NULL THEN 0

                   -- Pagó todo pero fuera de término -> podría ajustarse si quisieras
                   WHEN ap.fechaUltimoPago <= ex.fechaVto1 THEN 0

                   WHEN ap.fechaUltimoPago > ex.fechaVto1
                        AND (ex.fechaVto2 IS NULL OR ap.fechaUltimoPago <= ex.fechaVto2)
                        THEN ROUND(0.02 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)

                   WHEN ex.fechaVto2 IS NOT NULL AND ap.fechaUltimoPago > ex.fechaVto2
                        THEN ROUND(0.05 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)

                   ELSE 0
               END,

           -- 4) Total a pagar = deuda + interés
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
    JOIN afectados a
      ON a.idEstadoCuenta = ec.idEstadoCuenta
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