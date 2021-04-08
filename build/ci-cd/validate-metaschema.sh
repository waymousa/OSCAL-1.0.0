#!/bin/bash


if [ -z ${OSCAL_SCRIPT_INIT+x} ]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)/include/init-oscal.sh"
fi
source "$OSCALDIR/build/metaschema/scripts/include/init-schematron.sh"

# Option defaults
KEEP_TEMP_SCRATCH_DIR=false
WORKING_DIR="${OSCALDIR}"
VERBOSE=false
HELP=false

usage() {                                      # Function: Print a help message.
  cat << EOF
Usage: $0 [options]
Run all build scripts

-h, --help                        Display help
-w DIR, --working-dir DIR         Generate artifacts in DIR
-v                                Provide verbose output
--scratch-dir DIR                 Generate temporary artifacts in DIR
                                  If not provided a new directory will be
                                  created under \$TMPDIR if set or in /tmp.
--keep-temp-scratch-dir           If a scratch directory is automatically
                                  created, it will not be automatically removed.
EOF
}

OPTS=`getopt -o w:vh --long scratch-dir:,keep-temp-scratch-dir,working-dir:,help -n "$0" -- "$@"`
if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; usage ; exit 1 ; fi

# Process arguments
eval set -- "$OPTS"
while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    -w|--working-dir)
      WORKING_DIR="$(realpath "$2")"
      shift # past path
      ;;
    --scratch-dir)
      SCRATCH_DIR="$(realpath "$2")"
      shift # past path
      ;;
    --keep-temp-scratch-dir)
      KEEP_TEMP_SCRATCH_DIR=true
      ;;
    -v)
      VERBOSE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --) # end of options
      shift
      break;
      ;;
    *)    # unknown option
      echo "Unhandled option: $1"
      exit 1
      ;;
  esac
  shift # past argument
done

OTHER_ARGS=$@ # save the arg

if [ -z "${SCRATCH_DIR+x}" ]; then
  SCRATCH_DIR="$(mktemp -d)"
  if [ "$KEEP_TEMP_SCRATCH_DIR" != "true" ]; then
    function CleanupScratchDir() {
      rc=$?
      if [ "$VERBOSE" = "true" ]; then
        echo -e ""
        echo -e "${P_INFO}Cleanup${P_END}"
        echo -e "${P_INFO}=======${P_END}"
        echo -e "${P_INFO}Deleting scratch directory:${P_END} ${SCRATCH_DIR}"
      fi
      rm -rf "${SCRATCH_DIR}"
      exit $rc
    }
    trap CleanupScratchDir EXIT
  fi
fi

echo -e ""
echo -e "${P_INFO}Validating Metaschema Definitions${P_END}"
echo -e "${P_INFO}=================================${P_END}"

if [ "$VERBOSE" = "true" ]; then
  echo -e "${P_INFO}Using scratch directory:${P_END} ${SCRATCH_DIR}"
  echo -e "${P_INFO}Using working directory:${P_END} ${WORKING_DIR}"
fi

# compile the schematron
metaschema_toolchain="${OSCALDIR}/build/metaschema/toolchains/xslt-M4"
schematron="${metaschema_toolchain}/validate/metaschema-check.sch"
compiled_schematron="${SCRATCH_DIR}/metaschema-schematron-compiled.xsl"
metaschema_xsd="${metaschema_toolchain}/validate/metaschema.xsd"

build_schematron "$schematron" "$compiled_schematron"
cmd_exitcode=$?
if [ $cmd_exitcode -ne 0 ]; then
  echo -e "${P_ERROR}Compilation of Schematron '${P_END}${schematron}${P_ERROR}' failed.${P_END}"
  exit 1
fi
# the following is needed by the compiled template
cp "${metaschema_toolchain}/validate/metaschema-validation-support.xsl" "${SCRATCH_DIR}"
cp "${metaschema_toolchain}/validate/oscal-datatypes-check.xsl" "${SCRATCH_DIR}"
cp "${metaschema_toolchain}/validate/metaschema-metaprocess.xsl" "${SCRATCH_DIR}"
cp "${metaschema_toolchain}/validate/metaschema-collect.xsl" "${SCRATCH_DIR}"
cp "${metaschema_toolchain}/validate/metaschema-reduce1.xsl" "${SCRATCH_DIR}"
cp "${metaschema_toolchain}/validate/metaschema-digest.xsl" "${SCRATCH_DIR}"
cp "${metaschema_toolchain}/validate/metaschema-reduce2.xsl" "${SCRATCH_DIR}"


exitcode=0
shopt -s nullglob
shopt -s globstar
while IFS="|" read path gen_schema gen_converter gen_docs || [[ -n "$path" ]]; do
  shopt -s extglob
  [[ "$path" =~ ^[[:space:]]*# ]] && continue
  # remove leading space
  path="${path##+([[:space:]])}"
  # remove trailing space
  gen_docs="${gen_docs%%+([[:space:]])}"
  shopt -u extglob

  [ -z "$path" ] && continue;

  files_to_process="$OSCALDIR"/"$path"

  IFS= # disable word splitting
  for metaschema in $files_to_process
  do
    metaschema_relative=$(realpath --relative-to="$OSCALDIR" "$metaschema")
    if [ "$VERBOSE" = "true" ]; then
      echo -e "${P_INFO}Validating metaschema '${P_END}${metaschema_relative}${P_INFO}'.${P_END}"
    fi

    result=$(xmllint --nowarning --noent --noout --schema "${metaschema_xsd}" "$metaschema" 2>&1)
    cmd_exitcode=$?
    if [ $cmd_exitcode -ne 0 ]; then
      echo -e "${P_ERROR}XML Schema validation failed for metaschema '${P_END}${metaschema_relative}${P_ERROR}'.${P_END}"
      echo -e "${P_ERROR}${result}${P_END}"
      exitcode=1
    else
      svrl_result="$SCRATCH_DIR/svrl/${metaschema/$OSCALDIR\/src\//}.svrl"
      svrl_result_dir=${svrl_result%/*}
      mkdir -p "$svrl_result_dir"
      result=$(validate_with_schematron "$compiled_schematron" "$metaschema" "$svrl_result")
      cmd_exitcode=$?
      if [ $cmd_exitcode -ne 0 ]; then
        echo -e "${P_ERROR}Schematron validation failed for metaschema '${P_END}${metaschema_relative}${P_ERROR}'.${P_END}"
          echo -e "${P_ERROR}${result}${P_END}"
          exitcode=1
      else
        echo -e "${P_OK}XML Schema and Schematron validation passed for '${P_END}${metaschema_relative}${P_OK}'.${P_END}"
      fi
    fi
  done
done < $OSCALDIR/build/ci-cd/config/metaschema
shopt -u nullglob
shopt -u globstar

# cleanup compiled schematron
rm -f "$compiled_schematron"

exit $exitcode
