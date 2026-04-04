set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

setup:
    rokit install
    pesde install
    wally install

publish:
    pesde install
    wally install
    pesde publish
    wally publish

test:
    rojo sourcemap test.project.json -o sourcemap.json
    rojo serve test.project.json
