#!/usr/bin/env python3
"""Convert markdown files to PDF using basic HTML rendering"""

import sys
import os

def md_to_pdf(md_file, pdf_file):
    """Simple markdown to PDF conversion"""
    try:
        import markdown
        from weasyprint import HTML
    except ImportError:
        print("Required packages not found. Installing...")
        os.system(f"{sys.executable} -m pip install markdown weasyprint")
        import markdown
        from weasyprint import HTML
    
    # Read markdown file
    with open(md_file, 'r', encoding='utf-8') as f:
        md_content = f.read()
    
    # Convert to HTML
    html_content = markdown.markdown(md_content, extensions=['tables', 'fenced_code'])
    
    # Add styling
    styled_html = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <style>
            body {{ 
                font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
                line-height: 1.6; 
                padding: 40px; 
                max-width: 900px; 
                margin: 0 auto;
            }}
            h1, h2, h3 {{ color: #333; }}
            table {{ 
                border-collapse: collapse; 
                width: 100%; 
                margin: 20px 0; 
            }}
            th, td {{ 
                border: 1px solid #ddd; 
                padding: 12px; 
                text-align: left; 
            }}
            th {{ 
                background-color: #f8f9fa; 
                font-weight: bold; 
            }}
            code {{ 
                background-color: #f4f4f4; 
                padding: 2px 6px; 
                border-radius: 3px; 
                font-family: 'Consolas', 'Monaco', monospace; 
            }}
            pre {{ 
                background-color: #f8f9fa; 
                padding: 15px; 
                border-radius: 5px; 
                overflow-x: auto; 
            }}
            pre code {{ 
                background: none; 
                padding: 0; 
            }}
            blockquote {{ 
                border-left: 4px solid #ddd; 
                margin: 0; 
                padding-left: 20px; 
                color: #666; 
            }}
        </style>
    </head>
    <body>
        {html_content}
    </body>
    </html>
    """
    
    # Generate PDF
    HTML(string=styled_html).write_pdf(pdf_file)
    print(f"PDF generated: {pdf_file}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python md_to_pdf.py <input.md> <output.pdf>")
        sys.exit(1)
    
    md_to_pdf(sys.argv[1], sys.argv[2])
