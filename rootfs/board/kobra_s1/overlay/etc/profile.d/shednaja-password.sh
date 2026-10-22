# shellcheck shell=sh
# ShedNaja: as long as root still has the image's default password ("rockchip", the same
# on every printer), every interactive login warns and asks for a new one. Ctrl-C skips it
# for this login. The image hash uses a fixed salt, so equal hashes mean the default.
case $- in
*i*)
	_cur=$(sed -n 's/^root:\([^:]*\):.*/\1/p' /etc/shadow 2>/dev/null)
	_def=$(sed -n 's/^root:\([^:]*\):.*/\1/p' /usr/share/shednaja/shadow.default 2>/dev/null)
	if [ -t 0 ] && [ -n "$_cur" ] && [ "$_cur" = "$_def" ]; then
		echo
		echo "*** The root password is still the default one (\"rockchip\"). Anyone on your"
		echo "*** network can log in as root. Choose a new one now (Ctrl-C skips):"
		passwd root || echo "*** Password not changed - you will be asked again at the next login."
		echo
	fi
	unset _cur _def
	;;
esac
