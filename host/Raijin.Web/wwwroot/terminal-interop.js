// terminal-interop.js
//
// Thin JS interop bridge between Blazor's Terminal.razor component and
// xterm.js. One xterm instance per Blazor component, keyed by element id.
//
// Calls in (Blazor -> JS):  create / write / clear / fit / destroy
// Calls out (JS -> Blazor): OnTerminalInput(charCode)
//
// xterm handles ANSI escape codes natively, so any program that emits
// "\x1b[H" / "\x1b[2J" / colors / cursor moves is rendered correctly.
window.raijinTerminal = (function () {
    const instances = {};

    function create(elementId, dotNetRef) {
        const el = document.getElementById(elementId);
        if (!el) return false;

        const term = new window.Terminal({
            theme: {
                background:          '#000000',
                foreground:          '#e8e8e8',
                cursor:              '#ffffff',
                cursorAccent:        '#000000',
                selectionBackground: '#3a3a3a',
                black:   '#000000', red:    '#cccccc',
                green:   '#ffffff', yellow: '#cccccc',
                blue:    '#aaaaaa', magenta:'#cccccc',
                cyan:    '#dddddd', white:  '#ffffff',
                brightBlack:   '#666666', brightRed:    '#dddddd',
                brightGreen:   '#ffffff', brightYellow: '#dddddd',
                brightBlue:    '#bbbbbb', brightMagenta:'#dddddd',
                brightCyan:    '#eeeeee', brightWhite:  '#ffffff'
            },
            fontFamily: '"JetBrains Mono", "Cascadia Mono", Consolas, monospace',
            fontSize: 14,
            lineHeight: 1.25,
            cursorBlink: true,
            cursorStyle: 'block',
            convertEol: true,
            scrollback: 5000,
            allowProposedApi: true
        });

        const fitAddon = new window.FitAddon.FitAddon();
        term.loadAddon(fitAddon);
        term.open(el);
        try { fitAddon.fit(); } catch (_) { /* size not yet known */ }

        // Forward each input byte (or full pasted chunk) to .NET.
        term.onData(data => {
            for (let i = 0; i < data.length; i++) {
                dotNetRef.invokeMethodAsync('OnTerminalInput', data.charCodeAt(i));
            }
        });

        // Re-fit on container resize (window resize OR sidebar collapse, etc.)
        const ro = new ResizeObserver(() => {
            try { fitAddon.fit(); } catch (_) {}
        });
        ro.observe(el);

        instances[elementId] = { term, fitAddon, ro };
        return true;
    }

    function write(elementId, text) {
        const inst = instances[elementId];
        if (inst) inst.term.write(text);
    }

    function clear(elementId) {
        const inst = instances[elementId];
        if (inst) inst.term.clear();
    }

    function fit(elementId) {
        const inst = instances[elementId];
        if (inst) { try { inst.fitAddon.fit(); } catch (_) {} }
    }

    function focus(elementId) {
        const inst = instances[elementId];
        if (inst) { try { inst.term.focus(); } catch (_) {} }
    }

    function destroy(elementId) {
        const inst = instances[elementId];
        if (!inst) return;
        try { inst.ro.disconnect(); } catch (_) {}
        try { inst.term.dispose(); } catch (_) {}
        delete instances[elementId];
    }

    return { create, write, clear, fit, focus, destroy };
})();
