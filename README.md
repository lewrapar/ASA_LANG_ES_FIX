ASA_LANG_ES_FIX - LOCALIZACIÓN ESPAÑOLA REVERSIBLE
====================================================

EJECUTA UNICAMENTE:

  ASA_LANG_ES_FIX.bat

El menu permite:

1. Crear, verificar e instalar el parche.
2. Crear y verificar el PAK sin instalarlo.
3. Revertir el parche y restaurar los PAK anteriores.
4. Salir.

QUE INCLUYE
--------------
- Parchea los nombres de criaturas en la localización española oficial de ASA.
- Conserva las decenas de miles de cadenas oficiales en español.
- Cambia las claves existentes del CSV.
- Verifica que ninguna entrada ajena al CSV cambie o desaparezca.
- Es compatible con el mod S-Dino Variants (S-Dinos), incluyendo sus claves
  específicas de variantes.
- Es compatible con el mod Shiny Ascended (Shiny Dinos), aplicando los nombres
  base y alias traducidos; los calificadores dinámicos siguen perteneciendo al mod.

SEGURIDAD Y REVERSIÓN
---------------------
- Todos los artefactos descargados tienen versiones fijadas y se verifican automáticamente.
- No se usa ningun enlace "latest".
- No se modifica Game.ini.
- El PAK se construye y verifica antes de tocar Content\Paks.
- El nombre instalado termina en `_P.pak`, sufijo necesario para que ASA lo cargue como parche.
- Para instalar o revertir, el mismo BAT solicita elevacion UAC si es necesaria.
- El diagnostico trabaja dentro de RESULTADO_ULTIMA_EJECUCION y no escribe
  en la instalacion de ASA.
- La instalacion es transaccional. Si el commit falla, restaura automaticamente.
- Tras probar en el juego, puedes ejecutar el mismo BAT y elegir REVERTIR.
- Las copias de seguridad se guardan en:
  ShooterGame\Saved\LANG_ES_FIX_BACKUPS

PRUEBA
------
1. Cierra ASA.
2. Ejecuta el BAT y elige INSTALAR.
3. Mantén el parametro de Steam: -culture=es
4. Comprueba nombres base del CSV, criaturas S-Dino y criaturas Shiny.
5. Si no funciona, cierra ASA, ejecuta el mismo BAT y elige REVERTIR.

INFORMES
--------
RESULTADO_ULTIMA_EJECUCION contiene:
- INSTALACION.log.txt
- BUILD_REPORT.txt
- CAMBIOS_VERIFICADOS.csv
- MODS_ESPECIALES_DETECTADOS.json
- LANG_ES_FIX_P.pak

La FIX utiliza exclusivamente el CSV auditado situado en:
  source\correcciones_compiladas.csv
Para actualizar traducciones, edita este CSV y vuelve a generar la instalación
con el mismo BAT.

LICENCIA
--------
Este proyecto se distribuye bajo la licencia MIT. Al redistribuirlo, conserva
el aviso de copyright de Lewas_0 (lewrapar) incluido en el fichero LICENSE.
