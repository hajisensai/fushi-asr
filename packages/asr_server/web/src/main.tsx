import { createRoot } from 'react-dom/client';
import App from './App';
import logo from './assets/fushi-icon.png';
import { startLanguage } from './lib/i18n';
import '../styles.css';

// Language first: it decides <html lang/dir> and the document title before anything paints.
startLanguage();
// The icon ships inside the bundle, so the tab can have it without a second request.
const icon = document.createElement('link');
icon.rel = 'icon';
icon.href = logo;
document.head.append(icon);

createRoot(document.getElementById('root')!).render(<App />);
