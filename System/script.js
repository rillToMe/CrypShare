(() => {
  "use strict";

  document.addEventListener("DOMContentLoaded", () => {

    const loginForm = document.querySelector("#loginForm");
    const passwordInput = document.querySelector("#password");
    const toggleBtn = document.querySelector("#togglePass");
    const toggleUse = document.querySelector("#togglePassUse");
    const msg = document.querySelector("#message");

    if (toggleBtn && passwordInput && toggleUse) {
      toggleBtn.addEventListener("click", () => {
        const isText = passwordInput.type === "text";
        passwordInput.type = isText ? "password" : "text";
        toggleBtn.setAttribute("aria-pressed", String(!isText));
        toggleUse.setAttribute("href", isText ? "#ico-eye" : "#ico-eye-off");
        passwordInput.focus();
      });
    }

    if (loginForm && passwordInput) {
      loginForm.addEventListener("submit", (e) => {
        e.preventDefault();
        const entered = passwordInput.value.trim();
        const correct = "{PASSWORD}";
        if (entered === correct) {
          msg && (msg.textContent = "Berhasil masuk. Membuka daftar file...");
          setTimeout(() => (window.location.href = "files.html"), 300);
        } else {
          msg && (msg.textContent = "Password salah. Coba lagi.");
          passwordInput.value = "";
          passwordInput.focus();
        }
      });
    }

    const resetBtn = document.querySelector("#resetButton");
    const resetStatus = document.querySelector("#resetStatus");
    if (resetBtn) {
      resetBtn.addEventListener("click", async () => {
        resetBtn.disabled = true;
        try {
          await fetch("/__FORGET_FLAG.txt", { method: "PUT", body: "reset" });
          resetStatus && (resetStatus.textContent = "Permintaan reset terkirim.");
          setTimeout(() => (window.location.href = "index.html"), 900);
        } catch (err) {
          resetStatus && (resetStatus.textContent = "Gagal mengirim permintaan. Coba lagi.");
          console.error(err);
        } finally {
          resetBtn.disabled = false;
        }
      });
    }

    const tabs = Array.from(document.querySelectorAll(".tabs .tab"));
    const sectionsMap = {
      images: document.getElementById("images"),
      videos: document.getElementById("videos"),
      others: document.getElementById("others"),
    };

    function setActive(name){
      tabs.forEach(t => t.classList.toggle("active", t.dataset.target === name));
    }
    function fromHash(){
      const h = (location.hash || "#images").replace("#","");
      if (sectionsMap[h]) setActive(h);
    }
    tabs.forEach(t => {
      t.addEventListener("click", (e) => {
        const id = t.dataset.target;
        if (sectionsMap[id]) {
          e.preventDefault();
          sectionsMap[id].scrollIntoView({behavior:"smooth", block:"start"});
          history.replaceState(null, "", "#"+id);
          setActive(id);
        }
      });
    });

    if (window.IntersectionObserver){
      const obs = new IntersectionObserver((entries)=>{
        const vis = entries
          .filter(e => e.isIntersecting)
          .sort((a,b)=> b.intersectionRatio - a.intersectionRatio)[0];
        if (vis){
          const name = Object.keys(sectionsMap).find(k => sectionsMap[k] === vis.target);
          if (name) setActive(name);
        }
      }, {rootMargin: "-20% 0px -60% 0px", threshold:[0.25,0.5,0.75]});
      Object.values(sectionsMap).forEach(el => el && obs.observe(el));
    }

    fromHash();
    window.addEventListener("hashchange", fromHash);

    const RX = {
      img: /\.(png|jpe?g|gif|webp|bmp|svg)$/i,
      vid: /\.(mp4|webm|mov|mkv|avi)$/i,
      zip: /\.(zip|rar|7z)$/i,
    };
    const isImg = (s) => RX.img.test(s);
    const isVid = (s) => RX.vid.test(s);
    const isZip = (s) => RX.zip.test(s);
    const isFolderHref = (href) =>
      /\/download_folder\//i.test(href || "") || /\/$/.test(href || "");

    const toPreviewURL = (nameText) => "/uploads/" + encodeURIComponent((nameText || "").trim());

    function makeIcon(id) {
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
      svg.classList.add("file-ico");
      use.setAttributeNS("http://www.w3.org/1999/xlink", "href", id);
      use.setAttribute("href", id);
      svg.appendChild(use);
      return svg;
    }

    const imgList = document.querySelector("#images");
    const vidList = document.querySelector("#videos");
    const otherList = document.querySelector("#others");

    function renderFromListHTML_Old(serverHTML) {
      if (!(imgList && vidList && otherList)) return false;

      imgList.innerHTML = "";
      vidList.innerHTML = "";
      otherList.innerHTML = "";

      const tmp = document.createElement("div");
      tmp.innerHTML = serverHTML;
      const items = tmp.querySelectorAll("li");

      items.forEach((li) => {
        const a = li.querySelector("a");
        if (!a) return;

        const href = a.getAttribute("href") || "";
        const name = (a.textContent || "").trim();
        const low = (href + " " + name).toLowerCase();

        const link = document.createElement("a");
        link.href = href;
        link.textContent = name;
        link.prepend(makeIcon(
          isFolderHref(href) ? "#ico-folder" :
          isImg(low) ? "#ico-image" :
          isVid(low) ? "#ico-video" :
          isZip(low) ? "#ico-zip" : "#ico-file"
        ));

        const liNode = document.createElement("li");

        if (isImg(low) || isVid(low)) {
          const box = document.createElement("div");
          box.className = "media-box";

          if (isImg(low)) {
            const img = document.createElement("img");
            img.src = toPreviewURL(name);
            img.alt = name;
            box.appendChild(img);
          } else {
            const vid = document.createElement("video");
            vid.controls = true;
            vid.preload = "metadata";
            vid.src = toPreviewURL(name);
            box.appendChild(vid);
          }

          const linkRow = document.createElement("div");
          linkRow.style.marginTop = "10px";
          linkRow.appendChild(link);

          liNode.appendChild(box);
          liNode.appendChild(linkRow);

          (isImg(low) ? imgList : vidList).appendChild(liNode);
        } else {
          liNode.appendChild(link);
          otherList.appendChild(liNode);
        }
      });

      return true;
    }

    const fileListDiv = document.querySelector("#fileList");

    function renderFromListHTML_New(serverHTML) {
      if (!fileListDiv) return false;

      const tmp = document.createElement("div");
      tmp.innerHTML = serverHTML;

      const listItems = tmp.querySelectorAll("li");
      const ul = document.createElement("ul");
      ul.className = "grid-list";

      listItems.forEach((li) => {
        const a = li.querySelector("a");
        if (!a) return;

        const href = a.getAttribute("href") || "";
        const name = (a.textContent || "").trim();
        const infoText = (li.querySelector("span")?.textContent || "").trim(); 
        const low = (href + " " + name).toLowerCase();

        const card = document.createElement("li");
        card.className = "file-card";

        const box = document.createElement("div");
        box.className = "media-box";

        if (isImg(low)) {
          const img = document.createElement("img");
          img.src = toPreviewURL(name);
          img.alt = name;
          box.appendChild(img);
        } else if (isVid(low)) {
          const vid = document.createElement("video");
          vid.controls = true;
          vid.preload = "metadata";
          vid.src = toPreviewURL(name);
          box.appendChild(vid);
        } else {
          const wrap = document.createElement("div");
          wrap.className = "preview-icon";
          wrap.appendChild(
            makeIcon(
              isFolderHref(href) ? "#ico-folder" :
              isZip(low) ? "#ico-zip" :
              "#ico-file"
            )
          );
          box.appendChild(wrap);
        }

        const chip = document.createElement("a");
        chip.className = "file-chip";
        chip.href = href;
        chip.appendChild(
          makeIcon(
            isFolderHref(href) ? "#ico-folder" :
            isImg(low) ? "#ico-image" :
            isVid(low) ? "#ico-video" :
            isZip(low) ? "#ico-zip" : "#ico-file"
          )
        );
        chip.append(document.createTextNode(" " + name));

        const meta = document.createElement("div");
        meta.className = "meta";
        meta.textContent = infoText.replace(/^—\s*/, ""); 

        card.appendChild(box);
        card.appendChild(chip);
        if (meta.textContent) card.appendChild(meta);

        ul.appendChild(card);
      });

      fileListDiv.innerHTML = "";
      fileListDiv.appendChild(ul);
      return true;
    }

    async function fetchListHTML() {
      const res = await fetch("/list_html", { cache: "no-store" });
      return await res.text();
    }

    async function refreshList() {
      try {
        const html = await fetchListHTML();

        if (imgList && vidList && otherList) {
          renderFromListHTML_Old(html);
        }
        if (fileListDiv) {
          renderFromListHTML_New(html);
        }
      } catch (e) {
        console.error("refreshList failed", e);
      }
    }

    if (imgList || vidList || otherList) {
      renderFromListHTML_Old((imgList && imgList.innerHTML) || "");
    }
    if (fileListDiv) {
      renderFromListHTML_New(fileListDiv.innerHTML);
    }

    if (imgList || fileListDiv) {
      try {
        const es = new EventSource("/events");
        es.addEventListener("refresh", refreshList);
        es.addEventListener("ping", refreshList);
        es.onerror = () => {
          es.close();
          setInterval(refreshList, 3000);
        };
      } catch (_) {
        setInterval(refreshList, 3000);
      }
    }

    const btnTop = document.querySelector("#btnTop") || document.querySelector("#toTop");
    if (btnTop) {
      const onScroll = () => {
        const show = window.scrollY > 300;
        btnTop.style.display = show ? "block" : "none";
        if (btnTop.classList.contains("to-top")) {
          btnTop.classList.toggle("show", show);
        }
      };
      window.addEventListener("scroll", onScroll, { passive: true });
      btnTop.addEventListener("click", () =>
        window.scrollTo({ top: 0, behavior: "smooth" })
      );
      onScroll();
    }
  });
})();
