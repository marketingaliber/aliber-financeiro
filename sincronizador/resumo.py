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
    fornecedores, compras = fornecedores_e_compras(db_path)
    return {
        "versao": versao,
        "gerado_em": datetime.now().isoformat(timespec="seconds"),
        "data_ini": ini, "data_fim": data_fim.isoformat(),
        "vendas_dia": vendas_dia, "pagamentos_dia": pagamentos_dia,
        "fornecedores": fornecedores, "compras": compras,   # sempre a lista completa (não só o período)
        "contas_receber": contas_receber(db_path),           # crediário: lista completa
        "recebiveis_ini": max(data_ini, date.fromordinal(date.today().toordinal() - DIAS_RECEBIVEIS)).isoformat(),
        "recebiveis": recebiveis(db_path, max(data_ini, date.fromordinal(date.today().toordinal() - DIAS_RECEBIVEIS)), data_fim),
    }


def totais(resumo):
    """Totais para mostrar na tela do sincronizador e para conferência."""
    t = {"vendas": sum(d["qtd"] for d in resumo["vendas_dia"]),
         "faturamento": _r(sum(d["total"] for d in resumo["vendas_dia"])),
         "recebido": _r(sum(p["valor"] for p in resumo["pagamentos_dia"])),
         "canceladas": sum(d["canceladas_qtd"] for d in resumo["vendas_dia"]),
         "notas": len({c["origem_id"].split("#")[0] for c in resumo.get("compras", [])}),
         "fornecedores": len(resumo.get("fornecedores", [])),
         "a_receber": len([c for c in resumo.get("contas_receber", []) if c["situacao"] != "recebida"])}
    return t


# ---------------------------------------------------------------- compras (entrada de notas) e fornecedores
import base64
import gzip
import io
import re
import xml.etree.ElementTree as ET
import zipfile
import zlib


def so_digitos(s):
    return re.sub(r"\D", "", s or "")


def _abrir_xml(blob):
    """O PDV+ guarda o XML da nota compactado. Tenta os formatos comuns e devolve o texto do XML."""
    if not blob:
        return None
    dado = bytes(blob)
    tentativas = [lambda b: b, gzip.decompress, zlib.decompress, lambda b: zlib.decompress(b, -15),
                  lambda b: zipfile.ZipFile(io.BytesIO(b)).read(zipfile.ZipFile(io.BytesIO(b)).namelist()[0])]
    for _ in range(2):
        for t in tentativas:
            try:
                x = t(dado)
            except Exception:
                continue
            if b"<" in x[:400] and (b"infNFe" in x or b"<NFe" in x or b"nfeProc" in x):
                return x
        try:                                    # às vezes vem em base64
            dado = base64.b64decode(dado, validate=False)
        except Exception:
            break
    return None


def ler_nota(blob):
    """Parcelas (duplicatas), total e emitente do XML da NF-e. Devolve {} se não der para ler."""
    x = _abrir_xml(blob)
    if not x:
        return {}
    try:
        raiz = ET.fromstring(x)
    except ET.ParseError:
        return {}
    nome = lambda el: el.tag.rsplit("}", 1)[-1]
    filho = lambda el, n: next((c for c in el if nome(c) == n), None)
    txt = lambda el, n: (filho(el, n).text or "").strip() if el is not None and filho(el, n) is not None else ""
    out = {"parcelas": []}
    for el in raiz.iter():
        n = nome(el)
        if n == "dup":
            try:
                v = float(txt(el, "vDup") or 0)
            except ValueError:
                v = 0
            if v > 0:
                out["parcelas"].append({"numero": txt(el, "nDup"), "vencimento": txt(el, "dVenc")[:10], "valor": round(v, 2)})
        elif n == "ICMSTot":
            try:
                out["total"] = float(txt(el, "vNF") or 0)
            except ValueError:
                pass
        elif n == "ide":
            out["emissao"] = (txt(el, "dhEmi") or txt(el, "dEmi"))[:10]
        elif n == "emit":
            out["emit_cnpj"] = so_digitos(txt(el, "CNPJ") or txt(el, "CPF"))
            out["emit_nome"] = txt(el, "xNome")
            out["emit_fantasia"] = txt(el, "xFant")
            out["emit_ie"] = txt(el, "IE")
            end = filho(el, "enderEmit")
            out["emit_fone"] = txt(end, "fone") if end is not None else ""
    return out


def fornecedores_e_compras(db_path):
    """Fornecedores cadastrados no PDV+ e as contas a pagar geradas pelas entradas de mercadoria.

    Cada entrada vira uma conta por parcela (duplicata da NF-e). Sem duplicata no XML, vira uma
    conta só, com vencimento na emissão da nota (ou na data da entrada, se não tiver nota)."""
    con = conectar(db_path)
    try:
        tabelas = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
        if not {"entrada", "fornecedor"} <= tabelas:
            return [], []
        fornecedores = {}
        for f in con.execute("select * from fornecedor where data_hora_deletado is null"):
            doc = so_digitos(f["cpf_cnpj"])
            if doc:
                fornecedores[doc] = {"cpf_cnpj": doc, "razao_social": (f["razao_social"] or "").strip(),
                                     "nome_fantasia": (f["nome_fantasia"] or "").strip(), "fone": f["fone"] or "",
                                     "inscricao_estadual": f["inscricao_estadual"] or ""}
        tem_nota = "nota_fiscal_compra" in tabelas
        entradas = con.execute(
            f"""select e.id_entrada, e.data_hora, e.tipo_entrada, f.cpf_cnpj fcnpj, f.razao_social frazao, f.nome_fantasia ffant,
                       {"n.numero, n.serie, n.chave_acesso, n.data_hora_emissao, n.valor_total, n.nome_fornecedor, n.cpf_cnpj_fornecedor, n.xml_compactado, n.situacao"
                        if tem_nota else "null numero, null serie, null chave_acesso, null data_hora_emissao, null valor_total, null nome_fornecedor, null cpf_cnpj_fornecedor, null xml_compactado, null situacao"},
                       (select coalesce(sum(i.preco_custo_total),0) from entrada_item i where i.id_entrada=e.id_entrada and i.data_hora_deletado is null) itens
                  from entrada e
                  left join fornecedor f on f.id_fornecedor = e.id_fornecedor
                  {"left join nota_fiscal_compra n on n.id_nota_fiscal_compra = e.id_nota_fiscal_compra" if tem_nota else ""}
                 where e.data_hora_deletado is null""").fetchall()
    finally:
        con.close()

    compras = []
    for e in entradas:
        nota = ler_nota(e["xml_compactado"]) if e["xml_compactado"] else {}
        doc = so_digitos(e["fcnpj"] or e["cpf_cnpj_fornecedor"] or nota.get("emit_cnpj"))
        nome = (e["ffant"] or e["frazao"] or e["nome_fornecedor"] or nota.get("emit_fantasia") or nota.get("emit_nome") or "").strip()
        if not doc and not e["numero"]:
            continue                       # entrada interna (sem fornecedor e sem nota): não é conta a pagar
        if doc and doc not in fornecedores:  # fornecedor só na nota: cadastra também
            fornecedores[doc] = {"cpf_cnpj": doc, "razao_social": (e["nome_fornecedor"] or nota.get("emit_nome") or nome).strip(),
                                 "nome_fantasia": (nota.get("emit_fantasia") or "").strip(), "fone": nota.get("emit_fone", ""),
                                 "inscricao_estadual": nota.get("emit_ie", "")}
        data_entrada = (e["data_hora"] or "")[:10]
        emissao = (e["data_hora_emissao"] or nota.get("emissao") or data_entrada)[:10]
        total = float(e["valor_total"] or nota.get("total") or e["itens"] or 0)
        if total <= 0:
            continue
        parcelas = nota.get("parcelas") or [{"numero": "1", "vencimento": emissao, "valor": round(total, 2)}]
        num = f"NF {e['numero']}" if e["numero"] else "Entrada de mercadoria"
        for i, p in enumerate(parcelas, 1):
            compras.append({
                "origem_id": f"{e['id_entrada']}#{i}", "cpf_cnpj": doc,
                "descricao": f"{num} · {nome}" if nome else num,
                "documento": (f"NF {e['numero']}/{e['serie']}" if e["numero"] else "") + (f" parc. {p['numero'] or i}" if len(parcelas) > 1 else ""),
                "competencia": emissao, "vencimento": p["vencimento"] or emissao, "valor": p["valor"],
                "parcela": i if len(parcelas) > 1 else None, "parcelas": len(parcelas) if len(parcelas) > 1 else None,
                "data_entrada": data_entrada,
            })
    return list(fornecedores.values()), compras


# ---------------------------------------------------------------- contas a receber (crediário)
def contas_receber(db_path):
    """Parcelas do crediário do PDV+ (conta_pagar_receber, tipo 0) com o que já foi recebido.

    Vendas canceladas e parcelas apagadas ficam de fora. Situação: aberta, parcial ou recebida."""
    con = conectar(db_path)
    try:
        tabelas = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
        if "conta_pagar_receber" not in tabelas:
            return []
        tem_rec = "recebimento_pagamento" in tabelas
        contas = con.execute(
            """select c.id_conta_pagar_receber id, c.valor, c.vencimento, c.documento, c.data_hora_criado,
                      cl.nome, coalesce(cl.cpf, cl.cnpj) doc, cl.fone,
                      v.codigo_dispositivo, v.codigo_venda, v.data_hora_finalizada, v.nome_cliente
                 from conta_pagar_receber c
                 left join cliente cl on cl.id_cliente = c.id_cliente
                 left join venda v on v.id_venda = c.id_venda
                where c.data_hora_deletado is null and c.tipo_conta = 0 and coalesce(c.positiva_negativa, 1) = 1
                  and coalesce(v.cancelada_pelo_usuario, 0) = 0""").fetchall()
        recs = {}
        if tem_rec:
            for r in con.execute(
                    """select r.id_conta_pagar_receber id, substr(r.data_liquidacao,1,10) data, r.valor, r.juros_reais, r.multa_reais,
                              r.valor_liquidado, rv.codigo_dispositivo, rv.codigo_venda,
                              (select group_concat(p.forma_pagamento) from venda_forma_pagamento p where p.id_venda = r.id_venda
                                  and p.data_hora_deletado is null and coalesce(p.pagamento_cancelado_pelo_usuario,0)=0) formas
                         from recebimento_pagamento r
                         left join venda rv on rv.id_venda = r.id_venda
                        where r.data_hora_deletado is null and coalesce(rv.cancelada_pelo_usuario, 0) = 0"""):
                recs.setdefault(r["id"], []).append({
                    "data": r["data"], "valor": _r(r["valor"]), "juros": _r((r["juros_reais"] or 0) + (r["multa_reais"] or 0)),
                    "pago": _r(r["valor_liquidado"]), "formas": [int(x) for x in (r["formas"] or "").split(",") if x != ""],
                    "venda": f"{r['codigo_dispositivo']:03d}.{r['codigo_venda']}" if r["codigo_venda"] is not None else ""})
    finally:
        con.close()
    out = []
    for c in contas:
        rs = sorted(recs.get(c["id"], []), key=lambda x: x["data"] or "")
        principal = sum(x["valor"] for x in rs)
        valor = _r(c["valor"])
        situacao = "recebida" if rs and principal >= valor - 0.005 else ("parcial" if rs else "aberta")
        venda = f"{c['codigo_dispositivo']:03d}.{c['codigo_venda']}" if c["codigo_venda"] is not None else ""
        out.append({
            "origem_id": c["id"], "cliente": (c["nome"] or c["nome_cliente"] or "").strip(), "cliente_doc": so_digitos(c["doc"]),
            "cliente_fone": c["fone"] or "", "documento": c["documento"] or "", "venda": venda,
            "competencia": (c["data_hora_finalizada"] or c["data_hora_criado"] or "")[:10] or None,
            "vencimento": (c["vencimento"] or "")[:10] or None, "valor": valor,
            "valor_recebido": _r(sum(x["pago"] for x in rs)), "principal_recebido": _r(principal),
            "recebido_em": rs[-1]["data"] if situacao == "recebida" else None, "situacao": situacao, "recebimentos": rs,
        })
    return out


# ---------------------------------------------------------------- recebíveis das vendas (cada pagamento)
DIAS_RECEBIVEIS = 400       # histórico máximo de recebíveis enviado para a nuvem


def recebiveis(db_path, data_ini, data_fim):
    """Cada pagamento de venda do período (Pix, cartão, dinheiro...), com os dados da maquininha.

    Recebimento de crediário (venda sem itens) fica de fora: ele aparece dentro da parcela do crediário.
    O troco é descontado do dinheiro. O painel calcula taxa, prazo e situação pelas formas de pagamento."""
    ini = data_ini.isoformat()
    fim_excl = date.fromordinal(data_fim.toordinal() + 1).isoformat()
    con = conectar(db_path)
    try:
        tabelas = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
        tem_t = "venda_forma_pagamento_transacao" in tabelas
        linhas = con.execute(
            f"""select p.id_venda_forma_pagamento id, p.forma_pagamento forma, coalesce(p.valor,0) valor, p.bandeira_cartao bandeira,
                       v.id_venda, v.data_hora_finalizada quando, v.codigo_dispositivo, v.codigo_venda, coalesce(v.tipo_venda,1) tipo,
                       coalesce(v.valor_troco,0) troco, v.nome_cliente,
                       {"t.nsu_transacao nsu, t.codigo_autorizacao aut, t.parcela parcelas, t.tipo_parcelamento tparc"
                        if tem_t else "null nsu, null aut, null parcelas, null tparc"}
                  from venda_forma_pagamento p
                  join venda v on v.id_venda = p.id_venda
                  {"left join venda_forma_pagamento_transacao t on t.id_venda_forma_pagamento = p.id_venda_forma_pagamento and t.data_hora_deletado is null" if tem_t else ""}
                 where p.data_hora_deletado is null and coalesce(p.pagamento_cancelado_pelo_usuario,0)=0
                   and v.data_hora_deletado is null and coalesce(v.cancelada_pelo_usuario,0)=0
                   and v.data_hora_finalizada >= ? and v.data_hora_finalizada < ?
                   and coalesce(v.valor_total_liquido_itens,0) > 0
                   and exists (select 1 from venda_item i where i.id_venda=v.id_venda and i.data_hora_deletado is null and coalesce(i.cancelado,0)=0)
                 order by v.data_hora_finalizada""", (ini, fim_excl)).fetchall()
    finally:
        con.close()
    troco = {}
    out, vistos = [], set()
    for p in linhas:
        if p["id"] in vistos:          # mais de uma transação para o mesmo pagamento: usa a primeira
            continue
        vistos.add(p["id"])
        valor = float(p["valor"])
        if int(p["forma"]) == 0:
            resta = troco.setdefault(p["id_venda"], float(p["troco"]))
            tira = min(resta, valor)
            valor -= tira
            troco[p["id_venda"]] = resta - tira
        if valor <= 0:
            continue
        out.append({
            "origem_id": p["id"], "data": p["quando"][:10], "hora": p["quando"][11:16], "forma": int(p["forma"]),
            "valor": _r(valor), "venda": f"{p['codigo_dispositivo']:03d}.{p['codigo_venda']}" if p["codigo_venda"] is not None else "",
            "tipo_venda": int(p["tipo"]), "cliente": (p["nome_cliente"] or "").strip(),
            "bandeira": p["bandeira"], "nsu": p["nsu"] or "", "autorizacao": p["aut"] or "",
            "parcelas": max(1, int(p["parcelas"] or 1)),
        })
    return out
