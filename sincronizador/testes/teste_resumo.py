# -*- coding: utf-8 -*-
"""Teste do resumo com um banco mínimo no formato do PDV+ (sem dados de cliente)."""
import os
import sqlite3
import sys
import tempfile
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import resumo as R  # noqa: E402

ESQUEMA = """
create table venda (id_venda text primary key, data_hora_criado text, data_hora_deletado text,
  data_hora_finalizada text, cancelada_pelo_usuario int, tipo_venda int, valor_total real,
  valor_total_liquido_itens real, delivery_taxa_valor real, valor_total_taxas_servico real,
  valor_total_acrescimos real, desconto_reais real, valor_troco real);
create table venda_item (id_venda_item text primary key, id_venda text, data_hora_deletado text,
  cancelado int, preco_custo_unitario real, qtd real);
create table venda_forma_pagamento (id_venda_forma_pagamento text primary key, id_venda text,
  data_hora_deletado text, pagamento_cancelado_pelo_usuario int, forma_pagamento int, valor real);
"""


def criar_banco(caminho):
    c = sqlite3.connect(caminho)
    c.executescript(ESQUEMA)
    V = "insert into venda values (?,?,?,?,?,?,?,?,?,?,?,?,?)"
    # 1) balcão, R$ 50 pago com R$ 100 em dinheiro (troco 50)
    c.execute(V, ("v1", "2026-10-01T19:00", None, "2026-10-01T19:05", 0, 1, 50, 50, 0, 0, 0, 0, 50))
    c.execute("insert into venda_item values ('i1','v1',null,0,20,1)")
    c.execute("insert into venda_forma_pagamento values ('p1','v1',null,0,0,100)")
    # 2) delivery R$ 72 + 5 de entrega - 2 de desconto = 75, metade crédito metade Pix
    c.execute(V, ("v2", "2026-10-01T20:00", None, "2026-10-01T20:10", 0, 2, 75, 72, 5, 0, 0, 2, 0))
    c.execute("insert into venda_item values ('i2','v2',null,0,30,2)")
    c.execute("insert into venda_item values ('i2x','v2',null,1,99,1)")      # item cancelado: ignora
    c.execute("insert into venda_forma_pagamento values ('p2','v2',null,0,1,40)")
    c.execute("insert into venda_forma_pagamento values ('p3','v2',null,0,3,35)")
    # 3) cancelada (vem apagada no banco)
    c.execute(V, ("v3", "2026-10-02T19:00", "2026-10-02T19:30", None, 1, 3, 40, 40, 0, 0, 0, 0, 0))
    c.execute("insert into venda_item values ('i3','v3',null,0,10,1)")
    # 4) mesa no crediário
    c.execute(V, ("v4", "2026-10-02T21:00", None, "2026-10-02T22:00", 0, 3, 60, 60, 0, 0, 0, 0, 0))
    c.execute("insert into venda_item values ('i4','v4',null,0,25,1)")
    c.execute("insert into venda_forma_pagamento values ('p4','v4',null,0,2,60)")
    # 5) recebimento do crediário (sem itens) pago em Pix
    c.execute(V, ("v5", "2026-10-03T10:00", None, "2026-10-03T10:01", 0, 1, 60, 0, 0, 0, 0, 0, 0))
    c.execute("insert into venda_forma_pagamento values ('p5','v5',null,0,3,60)")
    # 6) em aberto (não finalizada): ignora
    c.execute(V, ("v6", "2026-10-03T11:00", None, None, 0, 3, 99, 99, 0, 0, 0, 0, 0))
    c.commit()
    c.close()


def rodar():
    erros = []

    def confere(nome, obtido, esperado):
        if abs((obtido or 0) - esperado) > 0.001:
            erros.append(f"{nome}: obtido {obtido}, esperado {esperado}")

    with tempfile.TemporaryDirectory() as pasta:
        db = os.path.join(pasta, "navi_db.db")
        criar_banco(db)
        ini, fim = R.periodo_disponivel(db)
        confere("primeiro dia", ini.toordinal(), date(2026, 10, 1).toordinal())
        r = R.montar(db, date(2026, 10, 1), date(2026, 10, 3), "teste")
        d = {(x["data"], x["tipo_venda"]): x for x in r["vendas_dia"]}
        p = {(x["data"], x["categoria"], x["forma"]): x["valor"] for x in r["pagamentos_dia"]}
        confere("balcão total", d[("2026-10-01", 1)]["total"], 50)
        confere("balcão custo", d[("2026-10-01", 1)]["custo"], 20)
        confere("delivery entrega", d[("2026-10-01", 2)]["taxa_entrega"], 5)
        confere("delivery desconto", d[("2026-10-01", 2)]["descontos"], 2)
        confere("delivery custo (sem item cancelado)", d[("2026-10-01", 2)]["custo"], 60)
        confere("canceladas", d[("2026-10-02", 3)]["canceladas_valor"], 40)
        confere("mesa total", d[("2026-10-02", 3)]["total"], 60)
        confere("dinheiro sem troco", p[("2026-10-01", "venda", 0)], 50)
        confere("crédito", p[("2026-10-01", "venda", 1)], 40)
        confere("crediário", p[("2026-10-02", "venda", 2)], 60)
        confere("recebimento crediário", p[("2026-10-03", "recebimento", 3)], 60)
        if ("2026-10-03", 1) in d:
            erros.append("recebimento de crediário contou como venda")
        t = R.totais(r)
        confere("vendas", t["vendas"], 3)
        confere("faturamento", t["faturamento"], 185)
    for e in erros:
        print("FALHOU:", e)
    print("OK" if not erros else f"{len(erros)} falha(s)")
    return 1 if erros else 0


if __name__ == "__main__":
    sys.exit(rodar())
