# -*- coding: utf-8 -*-
"""
Monta o painel a partir de painel.html:
  python montar.py                       -> ../docs/index.html (site publicado no GitHub Pages)
  python montar.py --demo resumo.json "Nome da loja" saida.html
                                          -> página de demonstração com vendas reais (não vai para o GitHub)
O endereço do Supabase vem de ../supabase/config.json  {"supabaseUrl": "...", "supabaseAnon": "..."}
"""
import json
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
fonte = open(os.path.join(AQUI, "painel.html"), encoding="utf-8").read()

if len(sys.argv) > 1 and sys.argv[1] == "--demo":
    resumo = json.load(open(sys.argv[2], encoding="utf-8"))
    demo = {"empresa": sys.argv[3], "vendas_dia": resumo["vendas_dia"], "pagamentos_dia": resumo["pagamentos_dia"],
            "contas_receber": resumo.get("contas_receber", []), "recebiveis": resumo.get("recebiveis", [])}
    pagina = fonte.replace("/*DEMO*/null/*FIM*/", "/*DEMO*/" + json.dumps(demo, ensure_ascii=False, separators=(",", ":")) + "/*FIM*/")
    open(sys.argv[4], "w", encoding="utf-8").write(pagina)
    print("demo:", sys.argv[4])
    sys.exit(0)

cfg_arq = os.path.join(AQUI, "..", "supabase", "config.json")
if os.path.exists(cfg_arq):
    cfg = json.load(open(cfg_arq, encoding="utf-8"))
    fonte = fonte.replace('const CONFIG = { supabaseUrl: "", supabaseAnon: "" };',
                          "const CONFIG = " + json.dumps({"supabaseUrl": cfg["supabaseUrl"], "supabaseAnon": cfg["supabaseAnon"]}) + ";")
pagina = ('<!doctype html>\n<html lang="pt-BR">\n<head>\n<meta charset="utf-8">\n'
          '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
          '<link rel="icon" href="icone.png">\n<meta name="theme-color" content="#143E7E">\n</head>\n<body>\n'
          + fonte + "\n</body>\n</html>\n")
os.makedirs(os.path.join(AQUI, "..", "docs"), exist_ok=True)
open(os.path.join(AQUI, "..", "docs", "index.html"), "w", encoding="utf-8").write(pagina)
print("site: docs/index.html")
