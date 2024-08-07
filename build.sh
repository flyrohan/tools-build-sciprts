#!/bin/bash
# (c) 2024, rohan
# Build Shell Script

###############################################################################
# Set build shell script
###############################################################################
eval "$(locale | sed -e 's/\(.*\)=.*/export \1=en_US.UTF-8/')"

BS_PROJECT_PATH="$(pwd)/tools/project"
BS_PROJECT_CONFIG="$(pwd)/.bs_project"
BS_PROJECT_EXTN='bs' # project file extention '*.bs'
BS_PROJECT=""
BS_PROJECT_SELECT=""
BS_EDITOR='vim' # editor with '-e' option

###############################################################################
# Build Functions
BS_SYSTEM_CMAKE_ORDER=('prepare' 'config' 'build' 'finalize' 'install' 'complete')
# shellcheck disable=SC2034
declare -A BS_SYSTEM_CMAKE=(
	['type']="cmake"
	['prepare']=bs_func_shell
	['config']=bs_cmake_config
	['build']=bs_cmake_build
	['finalize']=bs_func_shell
	['install']=bs_cmake_install
	['complete']=bs_func_shell
	['clean']=bs_cmake_clean
	['delete']=bs_remove_delete
	['command']=bs_cmake_command
	['order']=${BS_SYSTEM_CMAKE_ORDER[*]}
)

BS_SYSTEM_MESON_ORDER=('prepare' 'config' 'build' 'finalize' 'install' 'complete')
# shellcheck disable=SC2034
declare -A BS_SYSTEM_MESON=(
	['type']="meson"
	['prepare']=bs_func_shell
	['config']=bs_meson_setup
	['build']=bs_meson_build
	['finalize']=bs_func_shell
	['install']=bs_meson_install
	['complete']=bs_func_shell
	['clean']=bs_meson_clean
	['delete']=bs_remove_delete
	['command']=bs_meson_command
	['order']=${BS_SYSTEM_MESON_ORDER[*]}
)

BS_SYSTEM_MAKE_ORDER=('prepare' 'build' 'finalize' 'install' 'complete')
# shellcheck disable=SC2034
declare -A BS_SYSTEM_MAKE=(
	['type']="make"
	['prepare']=bs_func_shell
	['build']=bs_make_build
	['finalize']=bs_func_shell
	['install']=bs_make_install
	['complete']=bs_func_shell
	['clean']=bs_make_clean
	['delete']=bs_remove_delete
	['command']=bs_make_command
	['order']=${BS_SYSTEM_MAKE_ORDER[*]}
)

BS_SYSTEM_LINUX_ORDER=('prepare' 'defconfig' 'build' 'finalize' 'install' 'complete')
# shellcheck disable=SC2034
declare -A BS_SYSTEM_LINUX=(
	['type']="linux"
	['prepare']=bs_func_shell
	['defconfig']=bs_linux_defconfig
	['menuconfig']=bs_linux_menuconfig
	['build']=bs_linux_build
	['finalize']=bs_func_shell
	['install']=bs_make_install
	['complete']=bs_func_shell
	['clean']=bs_linux_clean
	['delete']=bs_remove_delete
	['command']=bs_linux_command
	['order']=${BS_SYSTEM_LINUX_ORDER[*]}
)

BS_SYSTEM_SHELL_ORDER=('prepare' 'build' 'finalize' 'install' 'complete')
# shellcheck disable=SC2034
declare -A BS_SYSTEM_SHELL=(
	['type']="shell"
	['build']=bs_shell_build
	['clean']=bs_shell_clean
	['delete']=bs_remove_delete
	['install']=bs_shell_install
	['prepare']=bs_func_shell
	['finalize']=bs_func_shell
	['complete']=bs_func_shell
	['command']=bs_shell_build
	['order']=${BS_SYSTEM_SHELL_ORDER[*]}
)

# build system list
BS_SYSTEM_LISTS=(
	BS_SYSTEM_CMAKE
	BS_SYSTEM_MESON
	BS_SYSTEM_MAKE
	BS_SYSTEM_LINUX
	BS_SYSTEM_SHELL
)

# options
_build_targets=()
_build_image=""
_build_verbose=false
_build_option=""
_build_command=""
_build_force=false
_build_jobs="-j$(grep -c processor /proc/cpuinfo)"
_project_lists=()

function logerr() { echo -e "\033[1;31m$*\033[0m"; }
function logmsg() { echo -e "\033[0;33m$*\033[0m"; }
function logext() {
	echo -e "\033[1;31m$*\033[0m"
	exit 1
}

function bs_prog_start() {
	local spin='-\|/' pos=0
	local delay=0.3 start=${SECONDS}
	while true; do
		local hrs=$(((SECONDS - start) / 3600))
		local min=$(((SECONDS - start - hrs * 3600) / 60))
		local sec=$(((SECONDS - start) - hrs * 3600 - min * 60))
		pos=$(((pos + 1) % 4))
		printf "\r\t: Progress |${spin:$pos:1}| %d:%02d:%02d" ${hrs} ${min} ${sec}
		sleep ${delay}
	done
}

function bs_prog_kill() {
	local pid=${_program_id}
	if pidof "${pid}"; then return; fi
	if [[ ${pid} -ne 0 ]] && [[ -e /proc/${pid} ]]; then
		kill "${pid}" 2>/dev/null
		wait "${pid}" 2>/dev/null
		echo ""
	fi
}

function bs_prog_run() {
	bs_prog_kill
	bs_prog_start &
	echo -en " ${!}"
	_program_id=${!}
}

trap bs_prog_kill EXIT

function bs_exec_sh() {
	local exec=${1} err

	# remove first,last space and set multiple space to single space
	exec="$(echo "${exec}" | sed 's/^[ \t]*//;s/[ \t]*$//;s/\s\s*/ /g')"
	logmsg " $ ${exec}"

	if [[ ${_build_verbose} == true ]]; then
		bash -c "${exec}"
		err=${?}
	else
		bs_prog_run
		bash -c "${exec}" >/dev/null 2>&1
		err=${?}
		bs_prog_kill
	fi

	return ${err}
}

# return 1 if current version($2) is greater than or equal to min version($1)
# else return 0
function bs_version_compare() {
	local min_v # ${1}
	local cur_v # ${2}

	[[ "$1" == "$2" ]] && return 0

	mapfile -t -d. min_v <<<"$1"
	mapfile -t -d. cur_v <<<"$2"

	for ((i = 0; i < ${#min_v[*]}; i++)); do
		if ((cur_v[i] > min_v[i])); then
			return 0
		elif ((cur_v[i] < min_v[i])); then
			return 1
		fi
	done

	return 0
}

function bs_copy_install() {
	declare -n args=${1}
	local dstdir=${args['install_directory']}
	local dstimg=() dstname=()
	local exec

	IFS=" " read -r -a dstimg <<<"${args['install_images']}"
	IFS=" " read -r -a dstname <<<"${args['install_names']}"

	[[ -z ${dstimg[*]} ]] && return

	if ! mkdir -p "${dstdir}"; then exit 1; fi

	# print install images
	for i in ${!dstimg[*]}; do
		if [[ ! -f "${dstimg[${i}]}" ]] && [[ ! -d "${dstimg[${i}]}" ]]; then
			logerr "   No such file or directory: '${dstimg[${i}]}'"
			if [[ ${_build_force} == true ]]; then
				# remove element
				unset 'dstimg[i]'
				continue
			fi
			return 1
		fi
		logmsg "   ${dstimg[${i}]} > $(realpath "${dstdir}/${dstname[${i}]}")"
	done

	[[ ${_build_verbose} == false ]] && bs_prog_run

	# copy install images
	for i in ${!dstimg[*]}; do
		# delete target directory
		if [[ -z ${dstname[$i]} ]] && [[ -d ${dstimg[$i]} ]] &&
			[[ -d "${dstdir}/$(basename "${dstimg[$i]}")" ]]; then
			bash -c "rm -rf ${dstdir}/$(basename "${dstimg[$i]}")"
		fi

		exec="cp -a ${dstimg[$i]} $(realpath "${dstdir}/${dstname[$i]}")"
		if [[ ${_build_verbose} == true ]]; then
			bash -c "${exec}"
			err=${?}
		else
			bash -c "${exec}" >/dev/null 2>&1
			err=${?}
		fi
	done

	[[ ${_build_verbose} == false ]] && bs_prog_kill

	return "${err}"
}

function bs_remove_delete() {
	declare -n args=${1}
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local exec="rm -rf ${outdir}"

	[[ -z ${outdir} ]] && return 0
	[[ $(realpath "${srcdir}") == $(realpath "${outdir}") ]] && return 0

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_func_shell() {
	declare -n args=${1} stat=${2}
	local cmd=${stat['command']} fn=""

	[[ ${cmd} == "prepare"  ]] && fn=${args['build_prepare']}
	[[ ${cmd} == "finalize" ]] && fn=${args['build_finalize']}
	[[ ${cmd} == "complete" ]] && fn=${args['install_complete']}

	[[ -z ${fn} ]] && return 0

	if [[ $(type -t "${fn}") == "function" ]]; then
		${fn} "${1}" "${2}" "${_build_option}"
	else
		bs_exec_sh "${fn}"
	fi

	return ${?}
}

function bs_cmake_config() {
	declare -n args=${1}
	local outdir=${args['build_directory']}

	[[ -z ${outdir} ]] && outdir="${args['source_directory']}/build"

	local exec=("cmake"
		"-S ${args['source_directory']}"
		"-B ${outdir}"
		"${args['build_config']}"
		"${_build_option}")

	# Reconfigue CMake
	if [[ -d ${outdir} && -f ${outdir}/CMakeCache.txt ]]; then
		if bs_version_compare "3.24" "$(cmake --version | head -1 | cut -f3 -d" ")"; then
			exec+=("--fresh")
		fi
	fi

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_cmake_build() {
	declare -n args=${1}
	declare -n outimg=args['build_images']
	local outdir=${args['build_directory']}
	local exec=()

	[[ -z ${outdir} ]] && outdir="${args['source_directory']}/build"

	exec=("cmake" "--build ${outdir}" "${args['build_option']}" "${_build_option}")

	if [[ ${_build_image} ]]; then
		exec+=("-t ${_build_image}")
	elif [[ "${outimg}" ]]; then
		exec+=("-t ${outimg}")
	fi

	bs_exec_sh "${exec[*]} ${_build_jobs}"

	return ${?}
}

function bs_cmake_command() {
	declare -n args=${1} stat=${2}
	local cmd=${stat['command']}
	local outdir=${args['build_directory']}
	local exec=("cmake" "--build ${outdir}" "${_build_option}" "${cmd}")

	[[ -z ${cmd} ]] && return 1
	[[ -z ${outdir} ]] && outdir="${args['source_directory']}/build"

	bs_exec_sh "${exec[*]} ${_build_jobs}"

	return ${?}
}

function bs_cmake_clean() {
	declare -n args=${1}
	local exec=("cmake" "--build ${args['build_directory']}"
		"${args['clean_option']}" "${_build_option}" "--target clean")

	[[ -z ${args['build_directory']} ]] && return 1

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_cmake_install() {
	declare -n args=${1}
	declare -n dstimg=args['install_images']
	local exec=("cmake" "--install ${args['build_directory']}")

	# If the type is 'cmake' and 'install_images' is not empty,
	# cmake system will copyies 'install_images' files to 'install_directory'
	# with the name 'install'
	if [[ -n "${dstimg}" ]]; then
		bs_copy_install "${1}"
		return ${?}
	fi

	if [[ -n ${args['install_directory']} ]]; then
		exec+=("--prefix ${args['install_directory']}")
	fi

	exec+=("${args['install_option']}" "${_build_option}")

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_meson_setup() {
	declare -n args=${1}
	local srcdir=${args['source_directory']}
	local outdir=${args['build_directory']}

	[[ -z ${outdir} ]] && outdir="${srcdir}/build"

	local exec=("meson" "setup" "${args['build_config']}"
		"${outdir}" "${srcdir}" "${_build_option}")

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_meson_build() {
	declare -n args=${1}
	declare -n outimg=args['build_images']
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local exec=()

	[[ -z ${outdir} ]] && outdir="${srcdir}/build"

	exec=("meson" "compile" -C "${outdir}" "${_build_option}")

	if [[ ${_build_image} ]]; then
		exec+=("${_build_image}")
	elif [[ "${outimg}" ]]; then
		exec+=("${outimg}")
	fi

	bs_exec_sh "${exec[*]} ${_build_jobs}"

	return ${?}
}

function bs_meson_command() {
	declare -n args=${1} stat=${2}
	local cmd=${stat['command']}
	local exec=("meson" "${cmd}" "${_build_option}")

	[[ -z ${cmd} ]] && return 1

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_meson_clean() {
	declare -n args=${1}
	declare -n outimg=args['build_images']
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local exec=()

	[[ -z ${outdir} ]] && outdir="${srcdir}/build"

	exec=("meson" "compile" "--clean" -C "${outdir}"
		"${args['clean_option']}" "${_build_option}")

	bs_exec_sh "${exec[*]} ${_build_jobs}"

	return ${?}
}

function bs_meson_install() {
	declare -n args=${1}
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local -n dstimg=args['install_images']
	local exec=("meson" "install")

	# If the type is 'meson' and 'install_images' is not empty,
	# meson system will copyies 'install_images' files to 'install directory'
	# with the name 'install'
	if [[ -n "${dstimg}" ]]; then
		bs_copy_install "${1}"
		return ${?}
	fi

	[[ -z ${outdir} ]] && outdir="${srcdir}/build"

	exec+=("-C ${outdir}")

	if [[ -n ${args['install_directory']} ]]; then
		exec+=("--destdir ${args['install_directory']}")
	fi

	exec+=("${args['install_option']}" "${_build_option}")

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_make_build() {
	declare -n args="${1}"
	local srcdir=${args['source_directory']}
	declare -n outimg=args['build_images']
	local exec=("make" "-C ${srcdir}" "${args['build_option']}" "${_build_option}")

	if [[ -n ${_build_image} ]]; then
		bs_exec_sh "${exec[*]} ${_build_image} ${_build_jobs}"
		return ${?}
	fi

	if [[ ${outimg} ]]; then
		for i in ${outimg}; do
			args['image']="${i}"
			if ! bs_exec_sh "${exec[*]} ${i} ${_build_jobs}"; then
				return 2
			fi
		done
		return 0
	fi

	bs_exec_sh "${exec[*]} ${_build_jobs}"

	return ${?}
}

function bs_make_command() {
	declare -n args=${1} stat=${2}
	local cmd=${stat['command']}
	local srcdir=${args['source_directory']}
	local exec=("make" "-C ${srcdir}" "${args['build_option']}" "${_build_option}")

	[[ -z ${cmd} ]] && return 1

	if [[ -n ${_build_image} ]]; then
		bs_exec_sh "${exec[*]} ${_build_image} ${cmd} ${_build_jobs}"
		return ${?}
	fi

	bs_exec_sh "${exec[*]} ${_build_jobs}"

	return ${?}
}

function bs_make_clean() {
	declare -n args=${1}
	local exec=("make" "-C ${args['source_directory']}"
		"${args['clean_option']}" "${_build_option}" "clean")

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_make_install() {
	declare -n args=${1}
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local cmd=${args['install_command']}
	local -n dstimg=args['install_images']
	local exec=("make")

	# If the type is 'make' and 'install_images' is not empty,
	# make system will copyies 'install_images' files to 'install directory'
	# with the name 'install'
	if [[ -z ${cmd} && -n "${dstimg}" ]]; then
		bs_copy_install "${1}"
		return ${?}
	fi

	[[ -z ${outdir} ]] && outdir="${srcdir}"
	[[ -z ${cmd} ]] && cmd="install"

	exec+=("-C ${outdir}" "${cmd}" "${args['install_option']}" "${_build_option}")

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_linux_defconfig() {
	declare -n args=${1} stat=${2}
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local exec=("make" "-C ${srcdir}")

	[[ -z ${args['build_config']} ]] && return 0

	if [[ -n ${outdir} ]] &&
	   [[ $(realpath "${outdir}") != "$(realpath "${srcdir}")" ]]; then
		exec+=("O=${outdir}")
	else
		outdir=${srcdir}
	fi

	if [[ ${_build_command} != "defconfig" && -f "${outdir}/.config" ]]; then
		logmsg " - skip defconfig, exist '${outdir}/.config' ..."
		return 0
	fi

	exec+=("${args['build_option']}" "${_build_option}" "${args['build_config']}")

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_linux_menuconfig() {
	declare -n args=${1}
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local exec=("make" "-C ${srcdir}")

	if [[ -n ${outdir} ]] &&
	   [[ $(realpath "${outdir}") != "$(realpath "${srcdir}")" ]]; then
		exec+=("O=${outdir}")
	fi

	# check default config
	if ! bs_linux_defconfig "${1}" "${2}"; then
		return 1
	fi

	exec+=("${args['build_option']}" "menuconfig")

	_build_verbose=true
	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_linux_build() {
	declare -n args=${1}
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local exec=("make" "-C ${srcdir}")

	if [[ -n ${outdir} ]] &&
	   [[ $(realpath "${outdir}") != "$(realpath "${srcdir}")" ]]; then
		exec+=("O=${outdir}")
	fi

	# check default config
	if ! bs_linux_defconfig "${1}" "${2}"; then
		return 1
	fi

	exec+=("${args['build_option']}" "${_build_option}")

	if [[ -n ${_build_image} ]]; then
		bs_exec_sh "${exec[*]} ${_build_image} ${_build_jobs}"
		return ${?}
	fi

	if [[ -n ${args['build_images']} ]]; then
		for i in ${args['build_images']}; do
			if ! bs_exec_sh "${exec[*]} ${i} ${_build_jobs}"; then
				return 2
			fi
		done
	else
		# buildroot has no image names
		bs_exec_sh "${exec[*]} ${_build_jobs}"
	fi

	return 0
}

function bs_linux_command() {
	declare -n args=${1} stat=${2}
	local cmd=${stat['command']}
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local exec=("make" "-C ${srcdir}")

	[[ -z ${cmd} ]] && return 1

	if [[ -n ${outdir} ]] &&
	   [[ $(realpath "${outdir}") != "$(realpath "${srcdir}")" ]]; then
		exec+=("O=${outdir}")
	fi

	[[ ${cmd} == *"menuconfig"* ]] && _build_verbose=true

	exec+=("${args['build_option']}" "${_build_option}" "${cmd}" "${_build_jobs}")

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_linux_clean() {
	declare -n args=${1}
	local srcdir=${args['source_directory']} outdir=${args['build_directory']}
	local exec=("make" "-C ${srcdir}")

	if [[ -n ${outdir} ]] &&
	   [[ $(realpath "${outdir}") != "$(realpath "${srcdir}")" ]]; then
		exec+=("O=${outdir}")
	fi

	exec+=("${args['clean_option']}" "${_build_option}" "clean")

	bs_exec_sh "${exec[*]}"

	return ${?}
}

function bs_shell_build() {
	declare -n args=${1}
	local srcdir=${args['source_directory']}
	local fn=${args['build_function']}

	[[ -z ${fn} ]] && return 0

	if [[ $(type -t "${fn}") == "function" ]]; then
		${fn} "${1}" "${2}" "${_build_option}"
	else
		if [[ -d ${srcdir} ]]; then
			pushd "${srcdir}" >/dev/null 2>&1
			logmsg " $ cd $(pwd)"
			fn="./${fn}"
		fi

		bs_exec_sh "${fn} ${args['build_option']} ${_build_option}"

		[[ -d ${srcdir} ]] && popd >/dev/null 2>&1
	fi

	return ${?}
}

function bs_shell_clean() {
	declare -n args=${1}
	local srcdir=${args['source_directory']}
	local fn=${args['clean_function']}

	if [[ -z ${fn} ]]; then
		if [[ -n ${args['build_function']} ]]; then
			fn=${args['build_function']}
		else
			return 0
		fi
	fi

	if [[ $(type -t "${fn}") == "function" ]]; then
		${fn} "${1}" "${2}" "${_build_option}"
	else
		if [[ -d ${srcdir} ]]; then
			pushd "${srcdir}" >/dev/null 2>&1
			logmsg " $ cd $(pwd)"
			fn="./${fn}"
		fi

		bs_exec_sh "${fn} ${args['clean_option']} ${_build_option}"

		[[ -d ${srcdir} ]] && popd >/dev/null 2>&1
	fi

	return ${?}
}

function bs_shell_install() {
	declare -n args=${1}
	local srcdir=${args['source_directory']}
	local fn=${args['install_function']}

	if [[ -z ${fn} ]]; then
		if [[ -n ${args['build_function']} ]]; then
			fn=${args['build_function']}
		else
			bs_copy_install "${1}"
			return ${?}
		fi
	fi

	if [[ $(type -t "${fn}") == "function" ]]; then
		${fn} "${1}" "${2}" "${_build_option}"
	else
		if [[ -d ${srcdir} ]]; then
			pushd "${srcdir}" >/dev/null 2>&1
			logmsg " $ cd $(pwd)"
			fn="./${fn}"
		fi

		bs_exec_sh "${fn} ${args['install_option']} ${_build_option}"

		[[ -d ${srcdir} ]] && popd >/dev/null 2>&1
	fi

	return ${?}
}

function bs_system_assign() {
	declare -n t=${1}

	[[ -n ${t['system']} ]] && return

	for l in "${BS_SYSTEM_LISTS[@]}"; do
		declare -n list=${l}
		if [[ ${t['build_type']} == "${list['type']}" ]]; then
			t['system']=${l}
			break
		fi
	done
}

function bs_target_list() {
	if [[ -z "${BS_PROJECT_TARGETS[*]}" ]]; then
		logerr " Not defined 'BS_PROJECT_TARGETS' in ${BS_PROJECT} !!!"
		exit 1
	fi

	logmsg " PROJECT    : ${BS_PROJECT} [${BS_PROJECT_SELECT}]\n"
	for t in "${BS_PROJECT_TARGETS[@]}"; do
		bs_system_assign "${t}"
		declare -n target=${t}
		printf "\033[0;33m %-10s : %-6s - %s\033[0m\n" \
			"* ${target['target_name']}" "${target['build_type']}" "${target['build_images']}"
	done
}

function bs_project_list() {
	local path=${BS_PROJECT_PATH}
	local array

	# get project lists
	array=$(find "${path}" -type f -name "*.${BS_PROJECT_EXTN}")
	for i in ${array}; do
		name=$(basename "${i}")
		name=${name%.*}
		_project_lists+=("${name}")
	done
}

function bs_project_save() {
	local project=${1}

	BS_PROJECT_SELECT="${BS_PROJECT_PATH}/${project}.${BS_PROJECT_EXTN}"
	if [[ -z ${project} || ! -f ${BS_PROJECT_SELECT} ]]; then
		logerr " Invalid PROJECT: ${project}, not exist ${BS_PROJECT_SELECT}"
		return 1
	fi

	logmsg " UPDATE     : ${project} [${BS_PROJECT_SELECT}] [${BS_PROJECT_CONFIG}]"

	# save project
	cat >"${BS_PROJECT_CONFIG}" <<EOF
PROJECT_PATH = ${BS_PROJECT_PATH}
PROJECT_SELECT = ${project}
EOF
	return 0
}

function bs_project_load() {
	local val

	if [[ ! -f ${BS_PROJECT_CONFIG} ]]; then
		return 1
	fi

	val=$(sed -n '/^\<PROJECT_SELECT\>/p' "${BS_PROJECT_CONFIG}")
	val=$(echo "${val}" | cut -d'=' -f 2)
	BS_PROJECT="${val//[[:space:]]/}"
	BS_PROJECT_SELECT="${BS_PROJECT_PATH}/${BS_PROJECT}.${BS_PROJECT_EXTN}"

	if [[ ! -f "${BS_PROJECT_SELECT}" ]]; then
		logerr " Not found PROJECT: ${BS_PROJECT_SELECT}"
		return 1
	fi

	return 0
}

function bs_project_edit() {
	${BS_EDITOR} "${BS_PROJECT_SELECT}"
}

function bs_project_menu() {
	local path=${BS_PROJECT_PATH} project
	local -a entry

	# get project lists
	[[ -z ${_project_lists[*]} ]] && bs_project_list

	# get porject menu lists
	for i in "${_project_lists[@]}"; do
		stat="OFF"
		entry+=("${i}")
		entry+=(" ")
		[[ ${i} == "${BS_PROJECT}" ]] && stat="ON"
		entry+=("${stat}")
	done

	if [[ -z ${entry[*]} ]]; then
		logerr " Not found build project in ${path}"
		exit 1
	fi

	if ! which whiptail >/dev/null 2>&1; then
		logext " Please install the whiptail"
	fi

	project=$(whiptail --title "Target PROJECT" \
		--radiolist "Select IN : ${BS_PROJECT_PATH}" 0 50 ${#entry[@]} -- "${entry[@]}" \
		3>&1 1>&2 2>&3)
	[[ -z ${project} ]] && exit 1

	BS_PROJECT="${project}"
	if ! (whiptail --title "Save/Exit" --yesno "Save" 8 78); then
		exit 1
	fi

	bs_project_save "${BS_PROJECT}"
}

function bs_usage_format() {
	echo -e " FORMAT: Target elements\n"
	echo -e " declare -A <TARGET>=("
	echo -e "\t['build_manual']=<name>          - build manually, [true|false] default false"
	echo -e "\t['target_name']=<name>           - build target name, required"
	echo -e "\t['build_type']=<type>            - build sytem type [cmake|meson|make|linux|shell], required"
	echo -e ""
	echo -e "\t['source_directory']=<dir>       - source path, required [cmake|meson|make|linux]"
	echo -e ""
	echo -e "\t['build_directory']=<dir>        - build output pathoptional"
	echo -e "\t['build_prepare']=<shell>        - shell for 'build', runs before 'config', optional"
	echo -e "\t['build_config']=<config>        - build configs, specify defconfig in [linux]"
	echo -e "\t['build_option']=<option>        - options for the 'build', and 'install' commands, optional"
	echo -e "\t['build_images']=<image>         - build target images, optional"
	echo -e "\t['build_function']=<shell>       - build shell function, required [shell]"
	echo -e "\t['build_finalize']=<shell>       - build shell, runs after 'build', optional"
	echo -e ""
	echo -e "\t['install_directory']=<dir>      - install directory for the builded images, optional"
	echo -e "\t['install_option']=<option>      - install options, optional"
	echo -e "\t['install_images']=<image>       - install image name, NOTE. must be full path."
	echo -e "\t                                   NOTE. If the 'install_images' is empty,"
	echo -e "\t                                         build system will install using the build system's command"
	echo -e "\t                                         e.g cmake --install <build_directory> --prefix <install_directory>"
	echo -e "\t['install_names']=<names>        - rename the installation image and copy it to ‘install_directory’, optional"
	echo -e "\t['install_command']=<command>    - install command, default install."
	echo -e "\t                                   NOTE. If the 'install_images' is not empty, this option is ignored"
	echo -e "\t['install_function']=<shell>     - install shell, required [shell]"
	echo -e "\t['install_complete']=<shell>     - install shell, runs after 'install', optional"
	echo -e ""
	echo -e "\t['clean_function']=<shell>       - clean shell, required [shell]"
	echo -e "\t['clean_option']=<option>        - clean options, optional"
	echo -e "\t)"
	echo -e ""
	echo -e " BS_PROJECT_TARGETS=( <TARGET> ... )"
	echo -e "\t'BS_PROJECT_TARGETS' is reserved"
	echo -e ""
}

function bs_usage_cmds() {
	echo -e " Commands supported by build-system :\n"
	for i in "${BS_SYSTEM_LISTS[@]}"; do
		declare -n t=${i}
		echo -ne "* ${t['type']}\t| commands : "
		for n in "${!t[@]}"; do
			[[ ${n} == "type" ]] && continue
			[[ ${n} == "name" ]] && continue
			[[ ${n} == "order" ]] && continue
			[[ ${n} == "command" ]] && continue
			echo -ne "${n} "
		done
		echo -ne "... "
		echo ""
		echo -ne "* \t| order    : ${t['order']}"
		echo ""
	done
}

function bs_usage() {
	case ${1} in
	'fmt')
		bs_usage_format
		exit 0
		;;
	'cmd')
		bs_usage_cmds
		exit 0
		;;
	*) ;;
	esac

	echo " Usage:"
	echo -e "\t$(basename "${0}") <option>"
	echo ""
	echo " option:"
	echo -e "\t-m \t\t select project with menuconfig"
	echo -e "\t-l\t\t listup projects at '${BS_PROJECT_PATH}'"
	echo -e "\t-p [project]\t select project."
	echo -e "\t-t [target...]\t select project's targets."
	echo -e "\t-i [image]\t select target's image."
	echo -e "\t-c [command]\t run commands supported by target."
	echo -e "\t-o [option]\t add option to config, build, install."
	echo -e "\t-f \t\t force build the next target even if a build error occurs"
	echo -e "\t-j [jobs]\t set build jobs"
	echo -e "\t-s\t\t show '${BS_PROJECT}' targets"
	echo -e "\t-e\t\t edit project '${BS_PROJECT}'"
	echo -e "\t-v\t\t verbose"
	echo -e "\t-h\t\t show help [fmt|cmd]"
	echo ""
}

function bs_build_args() {
	local listup=false show=false edit=false
	local project=''

	bs_project_load

	while getopts "mp:t:i:c:o:j:flsevh" opt; do
		case ${opt} in
		m)
			bs_project_menu
			exit 0
			;;
		p) project="${OPTARG}" ;;
		l) listup=true ;;
		t)
			_build_targets=("${OPTARG}")
			until [[ $(eval "echo \${$OPTIND}") =~ ^-.* ]] || [[ -z "$(eval "echo \${$OPTIND}")" ]]; do
				_build_targets+=("$(eval "echo \${$OPTIND}")")
				OPTIND=$((OPTIND + 1))
			done
			;;
		i) _build_image="${OPTARG}" ;;
		c) _build_command=${OPTARG} ;;
		s) show=true ;;
		o) _build_option="${OPTARG}" ;;
		f) _build_force=true ;;
		j) _build_jobs="-j${OPTARG}" ;;
		e) edit=true ;;
		v) _build_verbose=true ;;
		h)
			bs_usage "$(eval "echo \${$OPTIND}")"
			exit 0
			;;
		*) exit 1 ;;
		esac
	done

	if [[ ${listup} == true ]]; then
		bs_project_list
		[[ -z ${_project_lists[*]} ]] && logext " Not Found PROJECTS : ${BS_PROJECT_PATH}"

		logmsg " PROJECT    : ${BS_PROJECT} [${BS_PROJECT_SELECT}]"
		for i in "${_project_lists[@]}"; do logmsg "            - ${i}"; done
		exit 0
	fi

	if [[ -n ${project} ]]; then
		! bs_project_save "${project}" && exit 1
		! bs_project_load && exit 1
	fi

	if [[ ${show} == true ]]; then
		# shellcheck disable=SC1090
		source "${BS_PROJECT_SELECT}"
		bs_target_list
		exit 0
	fi

	if [[ ${edit} == true ]]; then
		bs_project_edit
		exit 0
	fi
}

function bs_build_check() {
	local target_name="${1}"

	if [[ -z "${BS_PROJECT_TARGETS[*]}" ]]; then
		logerr " Not defined 'BS_PROJECT_TARGETS' in ${BS_PROJECT} !!!"
		exit 1
	fi

	# Check build target
	if [[ -n ${target_name} ]]; then
		local found=false
		local -a list
		for i in "${BS_PROJECT_TARGETS[@]}"; do
			declare -n target=${i}
			list+=("'${target['target_name']}'")
			if [[ ${target['target_name']} == "${target_name}" ]]; then
				found=true
				break
			fi
		done
		if [[ ${found} == false ]]; then
			logerr " Error, unknown target : ${target_name} [ ${list[*]} ]"
			exit 1
		fi
	fi
}

function bs_build_run() {
	local target_name="${1}"

	bs_build_check "${target_name}"

	# Build
	for t in "${BS_PROJECT_TARGETS[@]}"; do

		# assign build system to the target['system']
		bs_system_assign "${t}"

		declare -n target=${t}
		declare -n system=${target['system']}
		# target's build status
		declare -A status=(['command']="")
		local ret="unknown"
		local cmd=${_build_command}

		if [[ -n ${target_name} &&
			${target['target_name']} != "${target_name}" ]]; then
			continue
		fi

		if [[ ${target['build_type']} != 'shell' ]] &&
			[[ ! -d ${target['source_directory']} ]]; then
			logerr " Error! not found source : '${target['target_name']}', ${target['source_directory']} !"
			continue
		fi

		if [[ -n ${cmd} ]]; then
			if printf '%s\0' "${!system[@]}" | grep -E -qwz "(${cmd})"; then
				func=${system[${cmd}]}
			else
				func=${system['command']}
			fi
			[[ -z ${func} ]] && logext " Not, implement command: '${cmd}'"

			status['command']="${cmd}"

			printf "\033[1;32m %-10s : %-10s\033[0m\n" "* ${target['target_name']}" "${status['command']}"
			if ! ${func} target status; then
				logext "-- Error, build verbose(-v) to print error log, build target --"
			fi
			ret="done"
		else
			printf "\033[1;32m ********** [ %s ] **********\033[0m\n" "${target['target_name']}"
			if [[ ${target['build_manual']} == true && -z ${target_name} ]]; then
				logmsg " - Build manually ..."
				continue
			fi

			declare -n order=system['order']

			for c in ${order}; do
				func=${system[${c}]}
				if [[ -z ${func} ]]; then
					logext " Not implement system : '${c}'"
				fi

				if [[ ${c} == 'prepare'  && -z ${target['build_prepare']} ]] ||
				   [[ ${c} == 'finalize' && -z ${target['build_finalize']} ]] ||
				   [[ ${c} == 'complete' && -z ${target['install_complete']} ]]; then
					continue
				fi

				status['command']="${c}"

				printf "\033[1;32m - %s\033[0m\n" "${status['command']}"
				if ! ${func} target status; then
					logerr "-- Error, build verbose(-v) to print error log, build all --"
					if [[ ${_build_force} == true ]]; then
						logerr "-- Continue the build forcefully --"
						continue
					fi
					exit 1
				fi
				ret="done"
				echo ""
			done
		fi

		if [[ ${ret} == "unknown" ]]; then
			logerr "-- Not support command: '${c}' for '${target['target_name']}'\n"
			bs_target_list
		fi
	done
}

###############################################################################
# Start Build !!!
###############################################################################

bs_build_args "${@}"

if [[ -z ${BS_PROJECT} ]]; then
	logerr " Not Selected Project, PATH: ${BS_PROJECT_PATH}"
	exit 0
fi

logmsg " PROJECT    : ${BS_PROJECT} [${BS_PROJECT_SELECT}]\n"
# shellcheck disable=SC1090
source "${BS_PROJECT_SELECT}"

if [[ -z "${_build_targets[@]}" ]]; then
	for t in "${BS_PROJECT_TARGETS[@]}"; do
		declare -n target=${t}
		_build_targets+=("${target['target_name']}")
	done
fi

for n in "${_build_targets[@]}"; do
	bs_build_run "${n}"
done
