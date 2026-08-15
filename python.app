from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
import pdfplumber
import re
import unicodedata
import pandas as pd
import os

app = Flask(__name__)
CORS(app)

def extract_text(file):
    """Extrai texto de um PDF usando pdfplumber"""
    try:
        # aceita tanto FileStorage quanto caminhos/streams
        stream = getattr(file, 'stream', file)
        try:
            stream.seek(0)
        except Exception:
            pass
        with pdfplumber.open(stream) as pdf:
            pages = []
            for page in pdf.pages:
                t = page.extract_text()
                if t:
                    pages.append(t)
            text = "\n".join(pages)
        return text if text else "Nenhum texto encontrado no PDF"
    except Exception as e:
        return f"Erro ao processar PDF: {e}"

def parse_data(text):
    """Procura informações básicas no texto"""
    if not text:
        return {'nome': '?', 'salario': '?', 'horas': '?'}

    # remove acentos e normaliza para facilitar buscas
    def norm(s):
        return unicodedata.normalize('NFKD', s).encode('ASCII', 'ignore').decode('ASCII').lower()

    ntext = norm(text)
    dados = {}

    # 1) tentar extrair nome a partir de linhas como 'EMPREGADO: NOME CARGO:'
    m_emp = re.search(r'EMPREGADO:\s*(.+?)(?:\s+CARGO:|\n|$)', text, flags=re.IGNORECASE)
    if m_emp:
        nome = m_emp.group(1).strip()
    else:
        m_nome = re.search(r'nome:\s*(.*)', ntext)
        nome = m_nome.group(1).strip().title() if m_nome else "?"
    dados['nome'] = nome

    # 2) tentar extrair salário a partir de 'REMUNERAÇÕES' ou 'SALÁRIO'
    m_rem = re.search(r'remunerac(?:oes|oes|ÃES|AÇÕES)?[:\s]*([0-9]{1,3}[0-9.,\s]*)', ntext)
    if not m_rem:
        m_rem = re.search(r'salario:\s*([0-9.,]+)', ntext)
    if m_rem:
        # pega o primeiro número válido na captura
        nums = re.findall(r'[0-9]+[.,][0-9]{2}', m_rem.group(1))
        dados['salario'] = nums[0] if nums else m_rem.group(1).strip()
    else:
        dados['salario'] = "?"

    # 3) tentar extrair horas a partir de 'DIAS/HORASTRAB' ou 'HORAS'
    m_dh = re.search(r'dias/?horastrab[:\s]*([0-9.,]+)', ntext)
    if not m_dh:
        m_dh = re.search(r'horas?:\s*([0-9.,]+)', ntext)
    if not m_dh:
        # procurar um padrão como 'DIAS/HORASTRAB 146,67' sem o ':'
        m_dh = re.search(r'dias/?horastrab\s+([0-9.,]+)', ntext)
    dados['horas'] = m_dh.group(1) if m_dh else "?"

    return dados

@app.route("/api/transcricoes", methods=["POST"])
def upload_pdf():
    """Recebe PDF, extrai texto e gera Excel"""
    if 'file' not in request.files:
        return jsonify({"error": "Nenhum arquivo enviado"}), 400

    file = request.files['file']
    text = extract_text(file)
    dados = parse_data(text)

    # Cria DataFrame e salva em Excel
    df = pd.DataFrame([dados])
    output_path = os.path.join("resultado.xlsx")
    try:
        df.to_excel(output_path, index=False)
    except Exception as e:
        return jsonify({"error": f"Erro ao salvar Excel: {e}. Verifique se 'openpyxl' está instalado."}), 500

    return jsonify({
        "raw": text,
        "dados": dados,
        "excel": output_path,
        "excel_url": f"http://{request.host}/download/resultado.xlsx",
        "app_url": f"http://{request.host}/"
    })

@app.route("/healthz")
def health():
    return jsonify({"status": "ok"})


@app.route("/")
def index():
    return send_from_directory("Front", "index.html")


@app.route('/front/<path:filename>')
def front_static(filename):
    return send_from_directory('Front', filename)


@app.route('/download/resultado.xlsx')
def download_result():
    path = 'resultado.xlsx'
    if os.path.exists(path):
        return send_from_directory('.', path, as_attachment=True)
    return jsonify({"error": "Arquivo não encontrado"}), 404

if __name__ == "__main__":
    # roda na interface 0.0.0.0 para permitir acesso na rede local
    app.run(host="0.0.0.0", debug=True)
