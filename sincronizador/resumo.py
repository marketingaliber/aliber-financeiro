# -*- coding: utf-8 -*-
"""
Aliber Financeiro - leitura do banco do PDV+ (somente LEITURA).

Monta o resumo diário das vendas que vai para o painel online:
  vendas_dia      por dia e tipo de venda (balcão, delivery, mesa): itens, entrega,
                  descontos, total, custo pelo cadastro e canceladas
  pagamentos_dia  por dia, categoria (venda ou recebimento de crediário) e forma de pagamento

Regras (conferidas no banco da Village Pizzaria):
  - venda válida = finalizada, não cancelada, não apagada (as canceladas ficam marcadas como
    apagadas no banco; entram só na contagem de canceladas)
  - "venda" sem itens = recebimento de crediário (não é receita nova, é dinheiro entrando)
  - valor_total = itens + taxa de entrega + taxa de serviço + acréscimos - desconto
  - o pagamento em dinheiro vem com o troco embutido: o troco é descontado do dinheiro
  - a data usada é a da finalização da venda (canceladas sem finalização: data de abertura)
"""
import sqlite3
from collections import defaultdict
from datetime import date, datetime

DB_PADRAO = r"C:\PDV+\.dart_tool\sqflite_common_ffi\databases\navi_db.db"

FORMAS = {0: "Dinheiro", 1: "Cartão de crédito", 2: "Crediário", 3: "Pix",
          4: "Cartão de débito", 5: "Forma 5", 6: "Forma 6", 7: "Forma 7"}
TIPOS = {1: "Balcão", 2: "Delivery", 3: "Mesa / comanda"}


def conectar(db_path):
    """Abre o banco só para leitura (o PDV+ continua funcionando normalmente)."""
    uri = "file:" + db_path.replace("\\", "/") + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=10)
    con.row_factory = sqlite3.Row
    return con


def _r(v):
    return round(float(v or 0) + 0.0, 2)


def periodo_disponivel(db_path):
    con = conectar(db_path)
    try:
        r = con.execute("select min(data_hora_finalizada), max(data_hora_finalizada) from venda "
                        "where data_hora_deletado is null and data_hora_finalizada is not null").fetchone()
    finally:
        con.close()
    if not r[0]:
        return None, None
    return date.fromisoformat(r[0][:10]), date.fromisoformat(r[1][:10])


def montar(db_path, data_ini, data_fim, versao=""):
    """Resumo do período [data_ini, data_fim] (datas inclusive), pronto para enviar."""
    ini = data_ini.isoformat()
    fim_excl = date.fromordinal(data_fim.toordinal() + 1).isoformat()
    con = conectar(db_path)
    try:
        vendas = con.execute(
            """select v.id_venda, substr(coalesce(v.data_hora_finalizada, v.data_hora_criado),1,10) as dia,
                      coalesce(v.tipo_venda,1) as tipo, coalesce(v.cancelada_pelo_usuario,0) as cancelada,
                      coalesce(v.valor_total,0) total, coalesce(v.valor_total_liquido_itens,0) itens,
                      coalesce(v.delivery_taxa_valor,0) entrega, coalesce(v.valor_total_taxas_servico,0) servico,
                      coalesce(v.valor_total_acrescimos,0) acresc, coalesce(v.desconto_reais,0) desconto,
                      coalesce(v.valor_troco,0) troco,
                      (select count(*) from venda_item i where i.id_venda=v.id_venda
                          and i.data_hora_deletado is null and coalesce(i.cancelado,0)=0) as n_itens,
                      (select coalesce(sum(coalesce(i.preco_custo_unitario,0)*coalesce(i.qtd,0)),0)
                         from venda_item i where i.id_venda=v.id_venda
                          and i.data_hora_deletado is null and coalesce(i.cancelado,0)=0) as custo
                 from venda v
                where (v.data_hora_deletado is null and coalesce(v.cancelada_pelo_usuario,0)=0
                       and v.data_hora_finalizada >= ? and v.data_hora_finalizada < ?)
                   or (coalesce(v.cancelada_pelo_usuario,0)=1          -- canceladas vêm apagadas
                       and coalesce(v.data_hora_finalizada, v.data_hora_criado) >= ?
                       and coalesce(v.data_hora_finalizada, v.data_hora_criado) < ?)""",
            (ini, fim_excl, ini, fim_excl)).fetchall()

        pags = defaultdict(list)
        for p in con.execute(
                """select p.id_venda, p.forma_pagamento forma, coalesce(p.valor,0) valor
                     from venda_forma_pagamento p join venda v on v.id_venda=p.id_venda
                    where p.data_hora_deletado is null and coalesce(p.pagamento_cancelado_pelo_usuario,0)=0
                      and v.data_hora_deletado is null and v.data_hora_finalizada >= ? and v.data_hora_finalizada < ?""",
                (ini, fim_excl)):
            pags[p["id_venda"]].append((int(p["forma"]), float(p["valor"])))
    finally:
        con.close()

    dias = defaultdict(lambda: defaultdict(float))
    pg = defaultdict(lambda: [0, 0.0])
    for v in vendas:
        recebimento = v["n_itens"] == 0 or v["itens"] <= 0
        if v["cancelada"]:
            if v["total"] > 0:
                d = dias[(v["dia"], v["tipo"])]
                d["canceladas_qtd"] += 1
                d["canceladas_valor"] += v["total"]
            continue
        categoria = "recebimento" if recebimento else "venda"
        if not recebimento:
            d = dias[(v["dia"], v["tipo"])]
            d["qtd"] += 1
            d["itens"] += v["itens"]
            d["taxa_entrega"] += v["entrega"]
            d["taxa_servico"] += v["servico"]
            d["acrescimos"] += v["acresc"]
            d["descontos"] += v["desconto"]
            d["total"] += v["total"]
            d["custo"] += v["custo"]
        troco = v["troco"]
        for forma, valor in pags.get(v["id_venda"], []):
            if forma == 0 and troco > 0:            # troco sai do dinheiro
                tira = min(troco, valor)
                valor -= tira
                troco -= tira
            k = (v["dia"], categoria, forma)
            pg[k][0] += 1
            pg[k][1] += valor

    vendas_dia = []
    for (dia, tipo), d in sorted(dias.items()):
        vendas_dia.append({
            "data": dia, "tipo_venda": int(tipo), "qtd": int(d["qtd"]),
            "itens": _r(d["itens"]), "taxa_entrega": _r(d["taxa_entrega"]), "taxa_servico": _r(d["taxa_servico"]),
            "acrescimos": _r(d["acrescimos"]), "descontos": _r(d["descontos"]), "total": _r(d["total"]),
            "custo": _r(d["custo"]), "canceladas_qtd": int(d["canceladas_qtd"]),
            "canceladas_valor": _r(d["canceladas_valor"]),
        })
    pagamentos_dia = [{"data": dia, "categoria": cat, "forma": forma, "qtd": q, "valor": _r(val)}
                      for (dia, cat, forma), (q, val) in sorted(pg.items())]
    return {
        "versao": versao,
        "gerado_em": datetime.now().isoformat(timespec="seconds"),
        "data_ini": ini, "data_fim": data_fim.isoformat(),
        "vendas_dia": vendas_dia, "pagamentos_dia": pagamentos_dia,
    }


def totais(resumo):
    """Totais para mostrar na tela do sincronizador e para conferência."""
    t = {"vendas": sum(d["qtd"] for d in resumo["vendas_dia"]),
         "faturamento": _r(sum(d["total"] for d in resumo["vendas_dia"])),
         "recebido": _r(sum(p["valor"] for p in resumo["pagamentos_dia"])),
         "canceladas": sum(d["canceladas_qtd"] for d in resumo["vendas_dia"])}
    return t
