import { useMemo } from "react";
import { formatDateRange, formatDistance } from "../lib/format";
import { distanceBetween } from "../lib/geo";
import Avatar from "./Avatar";

// One trip in the list: its cover, where and when, and who is going.
export default function TripCard({ trip, onOpen, selected = false }) {
  const { title, cover, stops, startsOn, endsOn, travellers } = trip;

  const distance = useMemo(() => {
    let total = 0;
    for (let i = 1; i < stops.length; i++) {
      total += distanceBetween(stops[i - 1].position, stops[i].position);
    }
    return total;
  }, [stops]);

  const shown = travellers.slice(0, 3);
  const more = travellers.length - shown.length;

  return (
    <article
      className={selected ? "trip-card selected" : "trip-card"}
      onClick={() => onOpen(trip.id)}
    >
      <img className="cover" src={cover.url} alt={cover.caption ?? title} />
      <div className="details">
        <h3>{title}</h3>
        <p className="when">{formatDateRange(startsOn, endsOn)}</p>
        <p className="where">
          {stops.length} stops · {formatDistance(distance)}
        </p>
      </div>
      <footer>
        {shown.map((person) => (
          <Avatar key={person.id} person={person} size={28} />
        ))}
        {more > 0 && <span className="more">+{more}</span>}
      </footer>
    </article>
  );
}
