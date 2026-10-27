# -*- coding: utf-8 -*-
"""Teste do resumo com um banco mínimo no formato do PDV+ (sem dados de cliente)."""
import os
import sqlite3
import sys
import gzip
import tempfile
import zlib
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import resumo as R  # noqa: E402

ESQUEMA = """
create table venda (id_venda text primary key, data_hora_criado text, data_hora_deletado text,
  data_hora_finalizada text, cancelada_pelo_usuario int, tipo_venda int, valor_total real,
  valor_total_liquido_itens real, delivery_taxa_valor real, valor_total_taxas_servico real,
  valor_total_acrescimos real, desconto_reais real, valor_troco real,
  codigo_dispositivo int default 1, codigo_venda int default 1, nome_cliente text);
create table venda_item (id_venda_item text primary key, id_venda text, data_hora_deletado text,
  cancelado int, preco_custo_unitario real, qtd real);
create table venda_forma_pagamento (id_venda_forma_pagamento text primary key, id_venda text,
  data_hora_deletado text, pagamento_cancelado_pelo_usuario int, forma_pagamento int, valor real, bandeira_cartao int);
"""


def criar_banco(caminho):
    c = sqlite3.connect(caminho)
    c.executescript(ESQUEMA)
    V = "insert into venda (id_venda, data_hora_criado, data_hora_deletado, data_hora_finalizada, cancelada_pelo_usuario, tipo_venda, valor_total, valor_total_liquido_itens, delivery_taxa_valor, valor_total_taxas_servico, valor_total_acrescimos, desconto_reais, valor_troco) values (?,?,?,?,?,?,?,?,?,?,?,?,?)"
    # 1) balcão, R$ 50 pago com R$ 100 em dinheiro (troco 50)
    c.execute(V, ("v1", "2026-10-01T19:00", None, "2026-10-01T19:05", 0, 1, 50, 50, 0, 0, 0, 0, 50))
    c.execute("insert into venda_item values ('i1','v1',null,0,20,1)")
    c.execute("insert into venda_forma_pagamento values ('p1','v1',null,0,0,100,null)")
    # 2) delivery R$ 72 + 5 de entrega - 2 de desconto = 75, metade crédito metade Pix
    c.execute(V, ("v2", "2026-10-01T20:00", None, "2026-10-01T20:10", 0, 2, 75, 72, 5, 0, 0, 2, 0))
    c.execute("insert into venda_item values ('i2','v2',null,0,30,2)")
    c.execute("insert into venda_item values ('i2x','v2',null,1,99,1)")      # item cancelado: ignora
    c.execute("insert into venda_forma_pagamento values ('p2','v2',null,0,1,40,2)")
    c.execute("insert into venda_forma_pagamento values ('p3','v2',null,0,3,35,null)")
    # 3) cancelada (vem apagada no banco)
    c.execute(V, ("v3", "2026-10-02T19:00", "2026-10-02T19:30", None, 1, 3, 40, 40, 0, 0, 0, 0, 0))
    c.execute("insert into venda_item values ('i3','v3',null,0,10,1)")
    # 4) mesa no crediário
    c.execute(V, ("v4", "2026-10-02T21:00", None, "2026-10-02T22:00", 0, 3, 60, 60, 0, 0, 0, 0, 0))
    c.execute("insert into venda_item values ('i4','v4',null,0,25,1)")
    c.execute("insert into venda_forma_pagamento values ('p4','v4',null,0,2,60,null)")
    # 5) recebimento do crediário (sem itens) pago em Pix
    c.execute(V, ("v5", "2026-10-03T10:00", None, "2026-10-03T10:01", 0, 1, 60, 0, 0, 0, 0, 0, 0))
    c.execute("insert into venda_forma_pagamento values ('p5','v5',null,0,3,60,null)")
    # 6) em aberto (não finalizada): ignora
    c.execute(V, ("v6", "2026-10-03T11:00", None, None, 0, 3, 99, 99, 0, 0, 0, 0, 0))
    c.commit()
    c.close()


XML_3_PARCELAS = """<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="http://www.portalfiscal.inf.br/nfe"><NFe><infNFe Id="NFe1">
<ide><nNF>4512</nNF><dhEmi>2026-10-05T10:00:00-03:00</dhEmi></ide>
<emit><CNPJ>12345678000190</CNPJ><xNome>ATACADAO UBA LTDA</xNome><xFant>Atacadão Ubá</xFant><enderEmit><fone>3235310000</fone></enderEmit><IE>123</IE></emit>
<total><ICMSTot><vNF>900.00</vNF></ICMSTot></total>
<cobr><dup><nDup>001</nDup><dVenc>2026-11-04</dVenc><vDup>300.00</vDup></dup><dup><nDup>002</nDup><dVenc>2026-12-04</dVenc><vDup>300.00</vDup></dup><dup><nDup>003</nDup><dVenc>2027-01-03</dVenc><vDup>300.00</vDup></dup></cobr>
</infNFe></NFe></nfeProc>"""
XML_SEM_PARCELA = """<NFe xmlns="http://www.portalfiscal.inf.br/nfe"><infNFe><ide><nNF>77</nNF><dhEmi>2026-10-10T08:00:00-03:00</dhEmi></ide>
<emit><CNPJ>99888777000166</CNPJ><xNome>LATICINIOS SERRA LTDA</xNome></emit><total><ICMSTot><vNF>250.50</vNF></ICMSTot></total></infNFe></NFe>"""


def criar_compras(caminho):
    c = sqlite3.connect(caminho)
    c.executescript("""
    create table fornecedor (id_fornecedor text primary key, data_hora_criado text, data_hora_deletado text, data_hora_ultima_alteracao text,
      razao_social text not null, nome_fantasia text not null, cpf_cnpj text not null, inscricao_estadual text, fone text);
    create table nota_fiscal_compra (id_nota_fiscal_compra text primary key, data_hora_criado text, data_hora_deletado text, data_hora_ultima_alteracao text,
      nome_fornecedor text not null, cpf_cnpj_fornecedor text not null, chave_acesso text not null, serie integer not null, numero integer not null,
      data_hora_emissao text not null, xml_compactado blob, situacao integer not null, valor_total real not null, manifestacao_realizada integer not null);
    create table entrada (id_entrada text primary key, data_hora_criado text, data_hora_deletado text, data_hora_ultima_alteracao text,
      id_fornecedor text, id_nota_fiscal_compra text, tipo_entrada integer not null, data_hora text not null);
    create table entrada_item (id_entrada_item text primary key, data_hora_criado text, data_hora_deletado text, data_hora_ultima_alteracao text,
      quantidade real not null, preco_custo real not null, preco_custo_total real not null, numero_item_nota_fiscal text, id_produto text not null, id_entrada text not null);
    """)
    c.execute("insert into fornecedor values ('f1',null,null,null,'ATACADAO UBA LTDA','Atacadão Ubá','12.345.678/0001-90','123','3235310000')")
    c.execute("insert into fornecedor values ('f2',null,null,null,'MOINHO ZONA DA MATA','Moinho','11.111.111/0001-11','','')")
    c.execute("insert into fornecedor values ('f3',null,'2026-01-01',null,'APAGADO','Apagado','22.222.222/0001-22','','')")
    c.execute("insert into nota_fiscal_compra values ('n1',null,null,null,'ATACADAO UBA LTDA','12345678000190','chave1',1,4512,'2026-10-05T10:00:00',?,1,900,1)", (gzip.compress(XML_3_PARCELAS.encode()),))
    c.execute("insert into nota_fiscal_compra values ('n2',null,null,null,'LATICINIOS SERRA LTDA','99888777000166','chave2',1,77,'2026-10-10T08:00:00',?,1,250.5,1)", (zlib.compress(XML_SEM_PARCELA.encode()),))
    c.execute("insert into entrada values ('e1',null,null,null,'f1','n1',1,'2026-10-06T09:00:00')")      # nota com 3 boletos
    c.execute("insert into entrada values ('e2',null,null,null,null,'n2',1,'2026-10-11T09:00:00')")      # nota sem duplicata, fornecedor só na nota
    c.execute("insert into entrada values ('e3',null,null,null,'f2',null,0,'2026-10-12T15:00:00')")      # entrada manual com fornecedor
    c.execute("insert into entrada_item values ('i1',null,null,null,10,12.5,125,null,'p1','e3')")
    c.execute("insert into entrada values ('e4',null,'2026-10-13',null,'f1',null,0,'2026-10-13T15:00:00')")  # apagada
    c.execute("insert into entrada values ('e5',null,null,null,null,null,0,'2026-10-14T15:00:00')")      # interna, sem fornecedor
    c.execute("insert into entrada_item values ('i2',null,null,null,1,50,50,null,'p1','e5')")
    c.commit()
    c.close()


def testar_receber(pasta, erros):
    db = os.path.join(pasta, "receber.db")
    c = sqlite3.connect(db)
    c.executescript("""
    create table cliente (id_cliente text primary key, nome text, cpf text, cnpj text, fone text);
    create table venda (id_venda text primary key, codigo_dispositivo int, codigo_venda int, data_hora_finalizada text,
      data_hora_criado text, cancelada_pelo_usuario int, nome_cliente text);
    create table venda_forma_pagamento (id_venda_forma_pagamento text primary key, id_venda text, data_hora_deletado text,
      pagamento_cancelado_pelo_usuario int, forma_pagamento int, valor real);
    create table conta_pagar_receber (id_conta_pagar_receber text primary key, data_hora_criado text, data_hora_deletado text,
      tipo_conta int, id_cliente text, id_venda text, positiva_negativa int, valor real, vencimento text, documento text);
    create table recebimento_pagamento (id_recebimento_pagamento text primary key, data_hora_deletado text, id_venda text,
      id_conta_pagar_receber text, valor real, juros_reais real, multa_reais real, valor_liquidado real, data_liquidacao text);
    insert into cliente values ('c1','Juliane','123.456.789-00',null,'(32) 99999-0000');
    insert into venda values ('v1',1,17,'2026-10-11T21:00:00',null,0,null), ('v2',1,18,'2026-10-12T21:00:00',null,1,null),
                             ('r1',1,40,'2026-11-10T10:00:00',null,0,null), ('r2',1,41,'2026-11-12T10:00:00',null,0,null);
    insert into venda_forma_pagamento values ('p1','r1',null,0,3,50), ('p2','r2',null,0,0,52);
    insert into conta_pagar_receber values
      ('a','2026-10-11',null,0,'c1','v1',1,100,'2026-11-11T00:00:00.000','001.17-1/2'),
      ('b','2026-10-11',null,0,'c1','v1',1,100,'2026-12-11T00:00:00.000','001.17-2/2'),
      ('x','2026-10-12','2026-10-12',0,'c1','v2',1,40,'2026-11-12T00:00:00.000','001.18-1/1'),
      ('y','2026-10-12',null,0,'c1','v2',1,40,'2026-11-12T00:00:00.000','001.18-1/1');
    insert into recebimento_pagamento values ('rp1',null,'r1','a',50,0,0,50,'2026-11-10'), ('rp2',null,'r2','a',50,2,0,52,'2026-11-12');
    """)
    c.commit()
    c.close()
    cr = {x["origem_id"]: x for x in R.contas_receber(db)}
    if set(cr) != {"a", "b"}:
        erros.append("contas a receber: esperado a e b (apagada e venda cancelada fora), veio " + str(sorted(cr)))
        return
    if cr["a"]["situacao"] != "recebida" or cr["a"]["recebido_em"] != "2026-11-12" or abs(cr["a"]["valor_recebido"] - 102) > .001:
        erros.append("parcela recebida em duas vezes com juros: " + str(cr["a"]))
    if cr["a"]["recebimentos"][0]["formas"] != [3]:
        erros.append("forma do recebimento (Pix) não veio")
    if cr["b"]["situacao"] != "aberta" or cr["b"]["vencimento"] != "2026-12-11" or cr["b"]["cliente_doc"] != "12345678900":
        erros.append("parcela em aberto errada: " + str(cr["b"]))


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
        rc = {x["origem_id"]: x for x in r["recebiveis"]}
        confere("recebível dinheiro sem troco", rc.get("p1", {}).get("valor"), 50)
        confere("recebível crédito", rc.get("p2", {}).get("valor"), 40)
        if "p5" in rc:
            erros.append("recebimento de crediário entrou como recebível de venda")
        if set(rc) != {"p1", "p2", "p3", "p4"}:
            erros.append("recebíveis esperados p1..p4, veio " + str(sorted(rc)))
        if r["compras"] or r["fornecedores"]:
            erros.append("banco sem tabelas de entrada deveria vir sem compras")
        criar_compras(db)
        forn, compras = R.fornecedores_e_compras(db)
        docs = {f["cpf_cnpj"] for f in forn}
        confere("fornecedores (2 cadastrados + 1 só na nota)", len(forn), 3)
        if "22222222000122" in docs:
            erros.append("fornecedor apagado foi enviado")
        if "99888777000166" not in docs:
            erros.append("fornecedor que só existe na nota não foi enviado")
        por = {c["origem_id"]: c for c in compras}
        confere("parcelas no total", len(compras), 5)
        confere("parcela 2 da NF 4512", por["e1#2"]["valor"], 300)
        if por["e1#3"]["vencimento"] != "2027-01-03" or por["e1#1"]["parcelas"] != 3:
            erros.append("vencimentos das duplicatas errados: " + str(por["e1#3"]))
        if por["e1#1"]["competencia"] != "2026-10-05":
            erros.append("competência deveria ser a emissão da nota")
        confere("nota sem duplicata vira uma conta", por["e2#1"]["valor"], 250.5)
        if por["e2#1"]["vencimento"] != "2026-10-10":
            erros.append("nota sem duplicata deveria vencer na emissão")
        confere("entrada manual pelo total dos itens", por["e3#1"]["valor"], 125)
        if any(k.startswith(("e4", "e5")) for k in por):
            erros.append("entrada apagada ou interna virou conta a pagar")
        testar_receber(pasta, erros)
    for e in erros:
        print("FALHOU:", e)
    print("OK" if not erros else f"{len(erros)} falha(s)")
    return 1 if erros else 0


if __name__ == "__main__":
    sys.exit(rodar())
